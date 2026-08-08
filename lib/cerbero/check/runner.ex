defmodule Cerbero.Check.Runner do
  @moduledoc "Orders pending migrations, threads the overlay, applies skips and severity overrides."

  alias Cerbero.Catalog
  alias Cerbero.Config
  alias Cerbero.Finding
  alias Cerbero.Migration

  @spec default_checks() :: [module()]
  def default_checks do
    [
      Cerbero.Check.UnsafeIndexCreation,
      Cerbero.Check.ConcurrentIndexRequiresAttributes,
      Cerbero.Check.NotNullOnPopulatedTable,
      Cerbero.Check.ColumnDefaultRewrite,
      Cerbero.Check.ColumnTypeChange,
      Cerbero.Check.FKValidationScan,
      Cerbero.Check.FKMissingIndex,
      Cerbero.Check.CRDBTransactionalDDL,
      Cerbero.Check.DMLInMigration,
      Cerbero.Check.RawDDLSafety,
      Cerbero.Check.MetaFindings
    ]
  end

  # The one pending-selection policy (snapshot and no-snapshot modes both
  # route here): a migration is history iff its version is non-nil AND
  # (already applied OR at/below the start_after cutoff). A nil-version
  # file is ALWAYS pending — it can never match an applied version or a
  # cutoff, and silently dropping it would violate never-silent.
  @spec split_pending([Migration.t()], [String.t()], String.t() | nil) ::
          {history :: [Migration.t()], pending :: [Migration.t()]}
  def split_pending(migrations, applied_versions, start_after) do
    applied = MapSet.new(applied_versions)

    {history, pending} =
      Enum.split_with(migrations, fn m ->
        m.version != nil and
          (MapSet.member?(applied, m.version) or
             (start_after != nil and m.version <= start_after))
      end)

    # nil sorts below any binary under Erlang term order, so nil-version
    # entries come first in pending — deliberate, they belong to no point
    # in the timestamp timeline.
    {history, Enum.sort_by(pending, & &1.version)}
  end

  @spec select_pending([Migration.t()], [String.t()], String.t() | nil) :: [Migration.t()]
  def select_pending(migrations, applied_versions, start_after) do
    {_history, pending} = split_pending(migrations, applied_versions, start_after)
    pending
  end

  @spec run([Migration.t()], Catalog.t(), Config.t(), [module()]) :: {[Finding.t()], Catalog.t()}
  def run(pending, %Catalog{} = catalog, %Config{} = config, checks \\ default_checks()) do
    # Third-party checks registered via extra_checks (validated against the
    # Cerbero.Check behaviour at config load) run after the given checks;
    # a builtin listed there is not run twice. Registration is additive
    # only — disabling a builtin goes through skip_checks, never here.
    checks = checks ++ (config.extra_checks -- checks)

    {findings, final_catalog} =
      Enum.map_reduce(pending, catalog, fn migration, cat ->
        findings =
          checks
          |> Enum.flat_map(fn check ->
            migration
            |> check.run(cat, config)
            |> Enum.map(&{check.id(), &1})
          end)
          |> Enum.map(fn {check_module_id, finding} ->
            finding
            |> apply_override(config)
            |> apply_skip(migration)
            |> apply_config_skip(check_module_id, config)
            |> apply_lock_timeout_attestation(config)
          end)

        {findings, Catalog.apply_migration(cat, migration)}
      end)

    {List.flatten(findings), final_catalog}
  end

  # Config-level policies for findings produced outside run/4 — today only
  # SnapshotHealth's global findings, which judge the snapshot rather than
  # a migration. Per-migration @cerbero_skip deliberately does not apply:
  # a global finding belongs to no single migration.
  @spec apply_policies([Finding.t()], atom(), Config.t()) :: [Finding.t()]
  def apply_policies(findings, check_module_id, %Config{} = config) do
    Enum.map(findings, fn finding ->
      finding
      |> apply_override(config)
      |> apply_config_skip(check_module_id, config)
      |> apply_lock_timeout_attestation(config)
    end)
  end

  defp apply_override(%Finding{} = finding, %Config{severity_overrides: overrides}) do
    case Map.fetch(overrides, finding.check) do
      {:ok, severity} -> %{finding | severity: severity}
      :error -> finding
    end
  end

  defp apply_skip(%Finding{} = finding, %Migration{attrs: %{cerbero_skip: skips}}) do
    case List.keyfind(skips, finding.check, 0) do
      {_, reason} ->
        %{
          finding
          | severity: :info,
            message: finding.message <> " (skipped: #{reason})",
            metadata: record_skip(finding.metadata, :migration_attribute, %{reason: reason})
        }

      nil ->
        finding
    end
  end

  defp apply_config_skip(%Finding{} = finding, check_module_id, %Config{skip_checks: skip_checks}) do
    if Enum.member?(skip_checks, check_module_id) do
      %{
        finding
        | severity: :info,
          message: finding.message <> " (skipped via config)",
          metadata: record_skip(finding.metadata, :config, %{})
      }
    else
      finding
    end
  end

  # A finding can be skipped through both routes at once; `via` is a list in
  # application order so a second route never clobbers the first's provenance
  # or reason (the post-merge audit caught apply_config_skip overwriting
  # apply_skip's record while the message honestly kept both suffixes).
  defp record_skip(metadata, via, extra) do
    Map.update(metadata, :skipped, Map.put(extra, :via, [via]), fn prev ->
      prev |> Map.merge(extra) |> Map.update!(:via, &(&1 ++ [via]))
    end)
  end

  # `lock_timeout_attested: true` is the team affirming their migration
  # sessions already set one (design §4). This only ANNOTATES findings
  # about a lock a `lock_timeout` would bound — it never changes severity
  # or silences anything; wired centrally here so every rule gets it for
  # free. Rules declare the lock they judged as `metadata: %{lock: ...}`
  # (structured, not message text — string matching missed SHARE ROW
  # EXCLUSIVE and broke on any wording edit); the write-blocking set below
  # mirrors Cerbero.Severity's private list, same trade-off as the copy in
  # Cerbero.Check.RawDDLSafety.
  @boundable_locks [:access_exclusive, :share, :share_row_exclusive]

  defp apply_lock_timeout_attestation(%Finding{} = finding, %Config{lock_timeout_attested: true}) do
    if finding.metadata[:lock] in @boundable_locks do
      %{finding | message: finding.message <> " (lock_timeout attested in .cerbero.exs)"}
    else
      finding
    end
  end

  defp apply_lock_timeout_attestation(%Finding{} = finding, %Config{}), do: finding
end
