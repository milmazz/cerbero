defmodule Cerbero.Check.NotNullOnPopulatedTable do
  @moduledoc "Rule 2: SET NOT NULL scans under AEL unless a validated IS NOT NULL CHECK exists (PG >= 12)."
  @behaviour Cerbero.Check

  alias Cerbero.Catalog
  alias Cerbero.Check.Helpers
  alias Cerbero.Operation, as: Op
  alias Cerbero.Severity
  alias Cerbero.SQL.Classifier.Classified

  @impl true
  def id, do: :not_null_on_populated_table

  @impl true
  def run(migration, catalog, config) do
    Helpers.fold_operations(migration, catalog, fn op, cat ->
      op
      |> set_not_null_targets()
      |> Enum.flat_map(fn {table, column, line} ->
        judge(table, column, line, migration, cat, config)
      end)
    end)
  end

  defp set_not_null_targets(%Op.AlterTable{table: t, ops: ops, line: line}) do
    for {:modify_column, col, _type, opts} <- ops,
        Keyword.get(opts, :null) == false,
        do: {t, col, line}
  end

  defp set_not_null_targets(%Op.RawSQL{classified: classified, line: line}) do
    for %Classified{class: :set_not_null, table: t, column: col} <- classified, do: {t, col, line}
  end

  defp set_not_null_targets(_), do: []

  defp judge(table, column, line, migration, catalog, config) do
    qualified = Catalog.qualify(table)

    cond do
      Catalog.born_empty?(catalog, table) ->
        []

      match?(%{not_null: true}, Catalog.column(catalog, table, column)) ->
        []

      catalog.engine == :postgres and catalog.version_num >= 120_000 and
          Catalog.validated_not_null_check?(catalog, table, column) ->
        [
          Helpers.finding(
            __MODULE__,
            :info,
            "SET NOT NULL on #{qualified}.#{column}: a validated IS NOT NULL CHECK exists, " <>
              "so the scan is skipped (PG >= 12); still takes ACCESS EXCLUSIVE briefly — set a lock_timeout",
            migration,
            line,
            relations: [qualified]
          )
        ]

      catalog.engine == :cockroachdb ->
        crdb_finding(table, column, line, migration, catalog, config)

      true ->
        scale = Catalog.scale(catalog, table)
        traffic = Catalog.traffic(catalog, table, config)

        severity =
          Severity.assess(
            :access_exclusive,
            :full_scan,
            scale,
            traffic,
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
              "SET NOT NULL on #{qualified}.#{column} (#{Helpers.describe_scale(catalog, table)}) " <>
                "forces a full-table scan under ACCESS EXCLUSIVE. Two-step instead: " <>
                "ADD CONSTRAINT ... CHECK (#{column} IS NOT NULL) NOT VALID, then VALIDATE CONSTRAINT " <>
                "in a later migration; on PG >= 12 the final SET NOT NULL then skips the scan",
              migration,
              line,
              relations: [qualified]
            )
          ]
        end
    end
  end

  # CockroachDB validates SET NOT NULL against existing rows with an online
  # scan (no table-level blocking lock, unlike PG's ACCESS EXCLUSIVE) — the
  # PG message's "full-table scan under ACCESS EXCLUSIVE" claim is simply
  # false there. Tiering shared with rule 3's CRDB cost note via
  # Helpers.crdb_cost_severity/3.
  defp crdb_finding(table, column, line, migration, catalog, config) do
    case Helpers.crdb_cost_severity(catalog, table, config) do
      nil ->
        []

      severity ->
        qualified = Catalog.qualify(table)

        [
          Helpers.finding(
            __MODULE__,
            severity,
            "SET NOT NULL on #{qualified}.#{column} (#{Helpers.describe_scale(catalog, table)}) " <>
              "runs as an online validation scan on CockroachDB, consuming cluster resources at scale",
            migration,
            line,
            relations: [qualified],
            engine: :cockroachdb
          )
        ]
    end
  end
end
