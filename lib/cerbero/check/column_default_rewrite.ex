defmodule Cerbero.Check.ColumnDefaultRewrite do
  @moduledoc "Rule 3: volatile defaults and GENERATED STORED columns rewrite the table."
  @behaviour Cerbero.Check

  alias Cerbero.{Catalog, Severity}
  alias Cerbero.Check.Helpers
  alias Cerbero.DDL.Effects

  @impl true
  def id, do: :column_default_rewrite

  @impl true
  def run(migration, catalog, config) do
    Helpers.fold_operations(migration, catalog, fn op, cat ->
      op
      |> Effects.derive(cat.engine, cat.version_num)
      |> Enum.filter(&(&1.class in [:add_column_volatile_default, :add_column_generated_stored]))
      |> Enum.flat_map(fn effect -> judge(effect, migration, cat, config) end)
    end)
  end

  defp judge(effect, migration, catalog, config) do
    table = Keyword.get(effect.relations, :target)

    cond do
      table == nil ->
        []

      Catalog.born_empty?(catalog, table) ->
        []

      catalog.engine == :cockroachdb ->
        crdb_finding(effect, table, migration, catalog, config)

      true ->
        postgres_finding(effect, table, migration, catalog, config)
    end
  end

  defp postgres_finding(effect, table, migration, catalog, config) do
    what =
      case effect.class do
        :add_column_volatile_default ->
          "a volatile default"

        :add_column_generated_stored ->
          "a GENERATED ... STORED column (rewrites on every PG version)"
      end

    scale = Catalog.scale(catalog, table)
    traffic = Catalog.traffic(catalog, table, config)

    severity =
      Severity.assess(:access_exclusive, :rewrite, scale, traffic, config, catalog.multiplier)

    if severity == :none do
      []
    else
      [
        Helpers.finding(
          __MODULE__,
          severity,
          "adding a column with #{what} forces a full-table rewrite of #{Catalog.qualify(table)} " <>
            "(#{Helpers.describe_scale(catalog, table)}) under ACCESS EXCLUSIVE. " <>
            "Add the column without the default, backfill in batches, then set the default",
          migration,
          effect.line,
          relations: [Catalog.qualify(table)],
          engine: :postgres
        )
      ]
    end
  end

  defp crdb_finding(effect, table, migration, catalog, config) do
    what =
      case effect.class do
        :add_column_volatile_default ->
          "a volatile default"

        :add_column_generated_stored ->
          "a GENERATED ... STORED column (rewrites on every version)"
      end

    case Helpers.crdb_cost_severity(catalog, table, config) do
      nil ->
        []

      severity ->
        [
          Helpers.finding(
            __MODULE__,
            severity,
            "adding a column with #{what} on #{Catalog.qualify(table)} " <>
              "(#{Helpers.describe_scale(catalog, table)}) triggers an online backfill that consumes " <>
              "cluster resources at scale",
            migration,
            effect.line,
            relations: [Catalog.qualify(table)],
            engine: :cockroachdb
          )
        ]
    end
  end
end
