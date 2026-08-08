defmodule Cerbero.Check.UnsafeIndexCreation do
  @moduledoc "Rule 1: non-concurrent create/drop index. Severity scales with size and traffic."
  @behaviour Cerbero.Check

  alias Cerbero.Catalog
  alias Cerbero.Check.Helpers
  alias Cerbero.DDL.CRDB
  alias Cerbero.DDL.Effects
  alias Cerbero.Operation, as: Op
  alias Cerbero.Severity

  @impl true
  def id, do: :unsafe_index_creation

  @impl true
  def description, do: "Non-concurrent index creation takes a SHARE lock that blocks writes for a full-table scan"

  @impl true
  def run(migration, catalog, config) do
    Helpers.fold_operations(migration, catalog, fn op, cat ->
      case op do
        %Op.CreateIndex{concurrently: false} -> judge(op, migration, cat, config)
        %Op.DropIndex{concurrently: false} -> judge(op, migration, cat, config)
        %Op.RawSQL{} -> judge(op, migration, cat, config)
        _ -> []
      end
    end)
  end

  defp judge(op, migration, catalog, config) do
    op
    |> Effects.derive(catalog.engine, catalog.version_num)
    |> Enum.filter(&(&1.class in [:create_index, :add_unique, :add_primary_key, :drop_index, :reindex]))
    |> Enum.flat_map(fn effect ->
      table = Keyword.get(effect.relations, :target)

      cond do
        table == nil ->
          []

        Catalog.born_empty?(catalog, table) ->
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
            "#{Helpers.lock_name(effect.lock)} lock blocks writes on #{qualified} (#{Helpers.describe_scale(catalog, table)}) for a full-table scan"

          :metadata_only ->
            "#{Helpers.lock_name(effect.lock)} lock on #{qualified} (#{Helpers.describe_scale(catalog, table)}) queues behind long-running queries; set a lock_timeout"
        end

      [
        Helpers.finding(
          __MODULE__,
          severity,
          mechanism <> "; " <> remediation(effect.class, partitioned),
          migration,
          effect.line,
          relations: [qualified],
          engine: catalog.engine,
          metadata: %{lock: effect.lock}
        )
      ]
    else
      []
    end
  end

  defp remediation(:drop_index, _), do: "use DROP INDEX CONCURRENTLY (drop index(..., concurrently: true))"

  defp remediation(_create, true),
    do:
      "partitioned parent: CREATE INDEX CONCURRENTLY is unsupported through PG 18 — build per-partition indexes CONCURRENTLY, create the parent index ON ONLY, then ATTACH each partition index"

  defp remediation(_create, false), do: "use concurrently: true with @disable_ddl_transaction and @disable_migration_lock"

  defp crdb_cost_finding(effect, table, migration, catalog, config) do
    # Deliberate destructuring tripwire: CRDB.judge(:create_index, _) is
    # {:limited, note} on every supported version. If the limitation table
    # ever changes that answer, this rule must be revisited — not silently
    # pass (a `with`/`else` here once swallowed :unknown scale entirely).
    {:limited, note} = CRDB.judge(:create_index, catalog.version_num)

    severity =
      Severity.assess(
        :online_schema_change,
        :full_scan,
        Catalog.scale(catalog, table),
        Catalog.traffic(catalog, table, config),
        config,
        catalog.multiplier
      )

    if severity == :none do
      []
    else
      [
        Helpers.finding(
          __MODULE__,
          severity,
          "index build on #{Catalog.qualify(table)} (#{Helpers.describe_scale(catalog, table)}) is online on CockroachDB but #{note}",
          migration,
          effect.line,
          relations: [Catalog.qualify(table)],
          engine: :cockroachdb,
          metadata: %{lock: :online_schema_change}
        )
      ]
    end
  end
end
