defmodule Cerbero.Check.SnapshotHealth do
  @moduledoc """
  Rule 8: the snapshot's own health, surfaced as findings — never silent
  decay, never exit 2. Staleness degrades confidence; absence is never
  safety.
  """

  alias Cerbero.{Catalog, Config, Finding, Migration, Snapshot}
  alias Cerbero.DDL.Effects
  alias Cerbero.Snapshot.Staleness

  @id :snapshot_health

  def id, do: @id

  @spec run_global(
          Snapshot.t(),
          Staleness.t(),
          [Migration.t()],
          [Migration.t()],
          Catalog.t(),
          Config.t()
        ) ::
          [Finding.t()]
  def run_global(snapshot, staleness, all_migrations, pending, catalog, config) do
    age_findings(staleness, config) ++
      invalid_index_findings(snapshot) ++
      divergence_findings(snapshot, all_migrations) ++
      aged_pending_findings(snapshot, pending, config) ++
      standby_findings(snapshot) ++
      absent_table_findings(pending, catalog)
  end

  defp finding(severity, message, opts \\ []) do
    %Finding{
      check: @id,
      severity: severity,
      message: message,
      file: Keyword.get(opts, :file),
      line: Keyword.get(opts, :line),
      relations: Keyword.get(opts, :relations, [])
    }
  end

  defp age_findings(%Staleness{age_days: age}, %Config{} = c) do
    cond do
      age > c.stale_degrade_days ->
        [
          finding(
            :warning,
            "snapshot is #{age} days old (limit #{c.stale_degrade_days}): every row count is now " <>
              "treated as unknown -> unbounded; risky operations fire at warning or above. Re-export"
          )
        ]

      age > c.stale_warn_days ->
        [
          finding(
            :warning,
            "snapshot is #{age} days old (warn threshold #{c.stale_warn_days}); re-export soon"
          )
        ]

      true ->
        []
    end
  end

  defp invalid_index_findings(%Snapshot{tables: tables}) do
    for t <- tables, idx <- t.indexes, idx.valid == false do
      finding(
        :warning,
        "index #{t.schema}.#{t.name}.#{idx.name} is invalid in production — likely a failed " <>
          "CONCURRENTLY build: it costs writes and provides nothing; drop and rebuild it",
        relations: ["#{t.schema}.#{t.name}"]
      )
    end
  end

  defp divergence_findings(%Snapshot{applied_migrations: applied}, all_migrations) do
    case applied do
      [] ->
        []

      _ ->
        max_applied = Enum.max(applied)
        applied_set = MapSet.new(applied)

        for m <- all_migrations,
            m.version != nil,
            m.version <= max_applied,
            not MapSet.member?(applied_set, m.version) do
          finding(
            :warning,
            "migration #{m.version} exists in the repo with version <= max(applied) but is absent from " <>
              "the snapshot's applied list — snapshot and repo disagree about history",
            file: m.file
          )
        end
    end
  end

  # Grace window: a migration authored within one deploy cycle of the
  # snapshot is normal PR churn (under nightly refresh, warning on every
  # predating migration flags most open PRs). Only past deploy_cadence days
  # does "still pending" become a stale-deploy signal worth surfacing.
  defp aged_pending_findings(%Snapshot{collected_at: collected_at}, pending, %Config{} = config) do
    grace_seconds = config.deploy_cadence * 86_400

    for m <- pending,
        m.version != nil,
        version_datetime = version_to_datetime(m.version),
        version_datetime != nil,
        DateTime.diff(collected_at, version_datetime, :second) > grace_seconds do
      finding(
        :warning,
        "pending migration #{m.version} predates the snapshot (#{DateTime.to_date(collected_at)}) " <>
          "by more than deploy_cadence (#{config.deploy_cadence}d) — it may already be applied " <>
          "(pending vs applied-after-snapshot is offline-indistinguishable); re-export",
        file: m.file
      )
    end
  end

  defp version_to_datetime(
         <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2>>
       ) do
    case DateTime.from_iso8601("#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}Z") do
      {:ok, dt, 0} -> dt
      _ -> nil
    end
  end

  defp version_to_datetime(_), do: nil

  defp standby_findings(%Snapshot{standby: true}) do
    [
      finding(
        :warning,
        "snapshot was taken on a hot standby: pg_stat activity counters are instance-local " <>
          "(n_live_tup ~ 0, analyze timestamps NULL) — traffic judgments are degraded"
      )
    ]
  end

  defp standby_findings(_), do: []

  # Absent-and-not-created-by-pending => unknown scale + a demand for re-export.
  defp absent_table_findings(pending, catalog) do
    {findings, _cat} =
      Enum.flat_map_reduce(pending, catalog, fn m, cat ->
        findings =
          m.operations
          |> Enum.flat_map(&Effects.derive(&1, cat.engine, cat.version_num))
          |> Enum.reject(&(&1.class == :create_table))
          |> Enum.flat_map(fn effect ->
            for {_role, table} <- effect.relations,
                is_binary(table),
                not Catalog.known?(cat, table) do
              finding(
                :error,
                "pending migration targets #{Catalog.qualify(table)}, which is absent from the snapshot " <>
                  "and not created by the pending set — absence is never safety; re-export the snapshot",
                file: m.file,
                line: effect.line,
                relations: [Catalog.qualify(table)]
              )
            end
          end)

        {findings, Catalog.apply_migration(cat, m)}
      end)

    Enum.uniq_by(findings, &{&1.file, &1.line, &1.message})
  end
end
