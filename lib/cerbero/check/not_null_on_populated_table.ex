defmodule Cerbero.Check.NotNullOnPopulatedTable do
  @moduledoc "Rule 2: SET NOT NULL scans under AEL unless a validated IS NOT NULL CHECK exists (PG >= 12)."
  @behaviour Cerbero.Check

  alias Cerbero.{Catalog, Severity}
  alias Cerbero.Check.Helpers
  alias Cerbero.Operation, as: Op
  alias Cerbero.SQL.Classifier.Classified

  @impl true
  def id, do: :not_null_on_populated_table

  @impl true
  def run(migration, catalog, config) do
    {findings, _} =
      Enum.reduce(migration.operations, {[], catalog}, fn op, {findings, current_catalog} ->
        new_findings =
          set_not_null_targets(op)
          |> Enum.flat_map(fn {table, column, line} ->
            judge(table, column, line, migration, current_catalog, config)
          end)

        updated_catalog = Catalog.apply(current_catalog, op)
        {findings ++ new_findings, updated_catalog}
      end)

    findings
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
      Catalog.born?(catalog, table) and not Catalog.backfilled?(catalog, table) ->
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
  # false there. Same tiering as rule 3's CRDB cost note (column_default_rewrite.ex):
  # >= rows_error warns, >= rows_warning informs, below that is silent;
  # unknown scale warns (unbounded, never small).
  defp crdb_finding(table, column, line, migration, catalog, config) do
    qualified = Catalog.qualify(table)

    with {:rows, rows, _} <- Catalog.scale(catalog, table),
         true <- rows >= config.rows_warning * catalog.multiplier do
      severity = if rows >= config.rows_error * catalog.multiplier, do: :warning, else: :info

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
    else
      :unknown ->
        [
          Helpers.finding(
            __MODULE__,
            :warning,
            "SET NOT NULL on #{qualified}.#{column} (scale unknown — treated as unbounded) " <>
              "runs as an online validation scan on CockroachDB, consuming cluster resources at scale",
            migration,
            line,
            relations: [qualified],
            engine: :cockroachdb
          )
        ]

      _ ->
        []
    end
  end
end
