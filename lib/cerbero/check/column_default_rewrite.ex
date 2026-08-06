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
    migration.operations
    |> Enum.flat_map(&Effects.derive(&1, catalog.engine, catalog.version_num))
    |> Enum.filter(&(&1.class in [:add_column_volatile_default, :add_column_generated_stored]))
    |> Enum.flat_map(fn effect ->
      table = Keyword.get(effect.relations, :target)
      scale = Catalog.scale(catalog, table)
      traffic = Catalog.traffic(catalog, table, config)

      what =
        case effect.class do
          :add_column_volatile_default ->
            "a volatile default"

          :add_column_generated_stored ->
            "a GENERATED ... STORED column (rewrites on every PG version)"
        end

      severity =
        Severity.assess(:access_exclusive, :rewrite, scale, traffic, config, catalog.multiplier)

      case {catalog.engine, severity} do
        {_, :none} ->
          []

        {:cockroachdb, sev} ->
          # CRDB online backfill doesn't block writes; cap at :warning
          sev = if sev == :error, do: :warning, else: sev

          [
            Helpers.finding(
              __MODULE__,
              sev,
              "adding a column with #{what} on #{Catalog.qualify(table)} " <>
                "(#{Helpers.describe_scale(catalog, table)}) triggers an online backfill that consumes " <>
                "cluster resources at scale",
              migration,
              effect.line,
              relations: [Catalog.qualify(table)],
              engine: :cockroachdb
            )
          ]

        {:postgres, sev} ->
          [
            Helpers.finding(
              __MODULE__,
              sev,
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
    end)
  end
end
