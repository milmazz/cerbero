defmodule Cerbero.Check.UnsafeIndexCreation do
  @moduledoc "Rule 1: non-concurrent create/drop index. Severity scales with size and traffic."
  @behaviour Cerbero.Check

  alias Cerbero.{Catalog, Severity}
  alias Cerbero.Check.Helpers
  alias Cerbero.DDL.{CRDB, Effects}
  alias Cerbero.Operation, as: Op

  @impl true
  def id, do: :unsafe_index_creation

  @impl true
  def run(migration, catalog, config) do
    {findings, _} =
      Enum.reduce(migration.operations, {[], catalog}, fn op, {findings, current_catalog} ->
        new_findings =
          case op do
            %Op.CreateIndex{concurrently: false} -> judge(op, migration, current_catalog, config)
            %Op.DropIndex{concurrently: false} -> judge(op, migration, current_catalog, config)
            %Op.RawSQL{} -> judge(op, migration, current_catalog, config)
            _ -> []
          end

        # Apply the operation to the catalog for subsequent operations in this migration
        updated_catalog = Catalog.apply(current_catalog, op)
        {findings ++ new_findings, updated_catalog}
      end)

    findings
  end

  defp judge(op, migration, catalog, config) do
    op
    |> Effects.derive(catalog.engine, catalog.version_num)
    |> Enum.filter(&(&1.class in [:create_index, :add_unique, :drop_index, :reindex]))
    |> Enum.flat_map(fn effect ->
      table = Keyword.get(effect.relations, :target)

      cond do
        table == nil ->
          []

        Catalog.born?(catalog, table) and not Catalog.backfilled?(catalog, table) ->
          []

        catalog.engine == :cockroachdb ->
          crdb_cost_finding(effect, table, migration, catalog, config)

        true ->
          pg_finding(effect, table, migration, catalog, config)
      end
    end)
  end

  defp pg_finding(effect, table, migration, catalog, config) do
    scale = Catalog.scale(catalog, table)
    traffic = Catalog.traffic(catalog, table, config)

    severity =
      Severity.assess(effect.lock, effect.cost, scale, traffic, config, catalog.multiplier)

    partitioned = match?(%{partitioned: true}, Catalog.table(catalog, table))

    emit? = severity in [:error, :warning] or config.strict_concurrent_index

    severity =
      if config.strict_concurrent_index and severity in [:info, :none],
        do: :warning,
        else: severity

    if emit? do
      qualified = Catalog.qualify(table)

      mechanism =
        case effect.cost do
          :full_scan ->
            "#{lock_name(effect.lock)} lock blocks writes on #{qualified} (#{Helpers.describe_scale(catalog, table)}) for a full-table scan"

          :metadata_only ->
            "#{lock_name(effect.lock)} lock on #{qualified} (#{Helpers.describe_scale(catalog, table)}) queues behind long-running queries; set a lock_timeout"
        end

      [
        Helpers.finding(
          __MODULE__,
          severity,
          mechanism <> "; " <> remediation(effect.class, partitioned),
          migration,
          effect.line,
          relations: [qualified],
          engine: catalog.engine
        )
      ]
    else
      []
    end
  end

  defp remediation(:drop_index, _),
    do: "use DROP INDEX CONCURRENTLY (drop index(..., concurrently: true))"

  defp remediation(_create, true),
    do:
      "partitioned parent: CREATE INDEX CONCURRENTLY is unsupported through PG 18 — build per-partition indexes CONCURRENTLY, create the parent index ON ONLY, then ATTACH each partition index"

  defp remediation(_create, false),
    do: "use concurrently: true with @disable_ddl_transaction and @disable_migration_lock"

  defp crdb_cost_finding(effect, table, migration, catalog, config) do
    with {:limited, note} <- CRDB.judge(:create_index, catalog.version_num),
         {:rows, rows, _} <- Catalog.scale(catalog, table),
         true <- rows >= config.rows_warning * catalog.multiplier do
      severity = if rows >= config.rows_error * catalog.multiplier, do: :warning, else: :info

      [
        Helpers.finding(
          __MODULE__,
          severity,
          "index build on #{Catalog.qualify(table)} (#{Helpers.describe_scale(catalog, table)}) is online on CockroachDB but #{note}",
          migration,
          effect.line,
          relations: [Catalog.qualify(table)],
          engine: :cockroachdb
        )
      ]
    else
      _ -> []
    end
  end

  defp lock_name(:share), do: "SHARE"
  defp lock_name(:access_exclusive), do: "ACCESS EXCLUSIVE"
  defp lock_name(:share_update_exclusive), do: "SHARE UPDATE EXCLUSIVE"
  defp lock_name(:share_row_exclusive), do: "SHARE ROW EXCLUSIVE"
  defp lock_name(other), do: other |> Atom.to_string() |> String.upcase()
end
