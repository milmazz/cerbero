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
    {findings, _} =
      Enum.reduce(migration.operations, {[], catalog}, fn op, {findings, current_catalog} ->
        new_findings =
          op
          |> Effects.derive(current_catalog.engine, current_catalog.version_num)
          |> Enum.filter(
            &(&1.class in [:add_column_volatile_default, :add_column_generated_stored])
          )
          |> Enum.flat_map(fn effect ->
            judge(effect, migration, current_catalog, config)
          end)

        updated_catalog = Catalog.apply(current_catalog, op)
        {findings ++ new_findings, updated_catalog}
      end)

    findings
  end

  defp judge(effect, migration, catalog, config) do
    table = Keyword.get(effect.relations, :target)

    cond do
      table == nil ->
        []

      Catalog.born?(catalog, table) and not Catalog.backfilled?(catalog, table) ->
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

    with {:rows, rows, _} <- Catalog.scale(catalog, table),
         true <- rows >= config.rows_warning * catalog.multiplier do
      severity = if rows >= config.rows_error * catalog.multiplier, do: :warning, else: :info

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
    else
      :unknown ->
        [
          Helpers.finding(
            __MODULE__,
            :warning,
            "adding a column with #{what} on #{Catalog.qualify(table)} " <>
              "(scale unknown — treated as unbounded) triggers an online backfill that consumes " <>
              "cluster resources at scale",
            migration,
            effect.line,
            relations: [Catalog.qualify(table)],
            engine: :cockroachdb
          )
        ]

      _ ->
        []
    end
  end
end
