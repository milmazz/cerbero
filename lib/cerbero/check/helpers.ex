defmodule Cerbero.Check.Helpers do
  @moduledoc "Shared rule scaffolding: the migration-local fold, message construction, finding assembly."

  alias Cerbero.Catalog
  alias Cerbero.Finding
  alias Cerbero.Migration

  @doc """
  The migration-local fold: judges each operation against the catalog as the
  operations before it leave it — `fun.(op, catalog)` returns the findings
  for one operation, then the op is applied via `Catalog.apply/2` so later
  ops in the same migration see the overlay.
  """
  @spec fold_operations(Migration.t(), Catalog.t(), (term(), Catalog.t() -> [Finding.t()])) ::
          [Finding.t()]
  def fold_operations(%Migration{} = migration, %Catalog{} = catalog, fun) do
    {findings, _catalog} =
      Enum.reduce(migration.operations, {[], catalog}, fn op, {findings, cat} ->
        {findings ++ fun.(op, cat), Catalog.apply(cat, op)}
      end)

    findings
  end

  @spec lock_name(atom()) :: String.t()
  def lock_name(:share), do: "SHARE"
  def lock_name(:access_exclusive), do: "ACCESS EXCLUSIVE"
  def lock_name(:share_update_exclusive), do: "SHARE UPDATE EXCLUSIVE"
  def lock_name(:share_row_exclusive), do: "SHARE ROW EXCLUSIVE"
  def lock_name(:row_exclusive), do: "ROW EXCLUSIVE"
  def lock_name(:online_schema_change), do: "online schema change"
  def lock_name(other), do: other |> Atom.to_string() |> String.upcase()

  @spec human_rows(non_neg_integer()) :: String.t()
  def human_rows(n) when n >= 1_000_000, do: trim_num(n / 1_000_000) <> "M"
  def human_rows(n) when n >= 1_000, do: trim_num(n / 1_000) <> "k"
  def human_rows(n), do: Integer.to_string(n)

  defp trim_num(f) do
    rounded = Float.round(f, 1)

    if rounded == Float.round(rounded, 0),
      do: Integer.to_string(trunc(rounded)),
      else: Float.to_string(rounded)
  end

  @spec stats_date(Catalog.t(), String.t()) :: String.t() | nil
  def stats_date(catalog, table) do
    case Catalog.table(catalog, table) do
      nil ->
        nil

      t ->
        case t.last_autoanalyze || t.last_analyze do
          nil -> nil
          %DateTime{} = dt -> dt |> DateTime.to_date() |> Date.to_iso8601()
        end
    end
  end

  @spec describe_scale(Catalog.t(), String.t()) :: String.t()
  def describe_scale(catalog, table) do
    case Catalog.scale(catalog, table) do
      {:rows, rows, _bytes} ->
        case stats_date(catalog, table) do
          nil -> "~#{human_rows(rows)} rows"
          date -> "~#{human_rows(rows)} rows, stats #{date}"
        end

      :zero ->
        "created in this deploy, empty by construction"

      :unknown ->
        "scale unknown — treated as unbounded"
    end
  end

  @doc """
  Finding assembly for every check, in-fold or global. `source` names where
  the finding anchors: a `%Migration{}` (only its `.file` is read), a bare
  file path when the caller has no migration struct in hand (SnapshotHealth
  judges the snapshot against migration *files*), or `nil` for a global
  finding about no file at all (e.g. snapshot age). Defaults: `relations`
  `[]`, `engine` `nil`, `metadata` `%{}`.
  """
  @spec finding(
          module(),
          Finding.severity(),
          String.t(),
          Migration.t() | String.t() | nil,
          integer() | nil,
          keyword()
        ) :: Finding.t()
  def finding(check_module, severity, message, source, line, opts \\ [])

  def finding(check_module, severity, message, %Migration{file: file}, line, opts),
    do: finding(check_module, severity, message, file, line, opts)

  def finding(check_module, severity, message, file, line, opts) when is_binary(file) or is_nil(file) do
    %Finding{
      check: check_module.id(),
      severity: severity,
      message: message,
      file: file,
      line: line,
      relations: Keyword.get(opts, :relations, []),
      engine: Keyword.get(opts, :engine),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
