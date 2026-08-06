defmodule Cerbero.Check.ColumnTypeChange do
  @moduledoc """
  Rule 4: type changes — rewrite + index rebuilds on PG; engine-rejection table on CRDB.

  Silences type changes on tables born in this deploy (not backfilled) — safe by construction.
  For unmappable DSL types (custom types), emits no finding: deliberate false-positive guard.
  CRDB: rejects type changes on indexed, constrained, or generated-stored columns.
  """
  @behaviour Cerbero.Check

  alias Cerbero.{Catalog, Severity}
  alias Cerbero.Check.Helpers
  alias Cerbero.DDL.CRDB
  alias Cerbero.Operation, as: Op

  @impl true
  def id, do: :column_type_change

  # Ecto DSL type -> formatted PG type (as pg_catalog formats it).
  @dsl_types %{
    integer: "integer",
    bigint: "bigint",
    text: "text",
    boolean: "boolean",
    uuid: "uuid",
    float: "double precision",
    naive_datetime: "timestamp without time zone",
    utc_datetime: "timestamp with time zone",
    date: "date",
    jsonb: "jsonb"
  }

  @impl true
  def run(migration, catalog, config) do
    {findings, _} =
      Enum.reduce(migration.operations, {[], catalog}, fn op, {findings, current_catalog} ->
        new_findings =
          case op do
            %Op.AlterTable{table: table, ops: ops, line: line} ->
              for {:modify_column, col, type, opts} <- ops,
                  type != nil,
                  new_type = format_type(type, opts),
                  current = Catalog.column(current_catalog, table, col),
                  # Born-this-deploy silencing: if table was created in this deploy and not backfilled, skip
                  not (Catalog.born?(current_catalog, table) and
                         not Catalog.backfilled?(current_catalog, table)),
                  finding <-
                    judge(table, col, current, new_type, line, migration, current_catalog, config) do
                finding
              end

            _ ->
              []
          end

        # Apply the operation to the catalog for subsequent operations in this migration
        updated_catalog = Catalog.apply(current_catalog, op)
        {findings ++ new_findings, updated_catalog}
      end)

    findings
  end

  defp judge(_table, _col, %{type: current}, new_type, _line, _m, _cat, _cfg)
       when current == new_type, do: []

  defp judge(_table, _col, nil, _new, _line, _m, _cat, _cfg), do: []

  # Guard against unmappable types: if new_type is nil, emit no finding
  defp judge(_table, _col, _current, nil, _line, _m, _cat, _cfg), do: []

  defp judge(table, col, %{type: current}, new_type, line, migration, catalog, config) do
    qualified = Catalog.qualify(table)

    if catalog.engine == :cockroachdb do
      crdb_judge(qualified, col, line, migration, catalog)
    else
      scale = Catalog.scale(catalog, table)
      traffic = Catalog.traffic(catalog, table, config)
      coercible = binary_coercible?(current, new_type)
      cost = if coercible, do: :metadata_only, else: :rewrite

      severity =
        Severity.assess(:access_exclusive, cost, scale, traffic, config, catalog.multiplier)

      if severity == :none do
        []
      else
        message =
          if coercible do
            "#{qualified}.#{col} #{current} -> #{new_type} is binary-coercible (metadata only) " <>
              "but still takes ACCESS EXCLUSIVE — acquisition queues behind long-running queries; set a lock_timeout"
          else
            indexes = indexes_on(catalog, table, col)

            "#{qualified}.#{col} #{current} -> #{new_type} rewrites the table " <>
              "(#{Helpers.describe_scale(catalog, table)}) under ACCESS EXCLUSIVE" <>
              case indexes do
                [] -> ""
                names -> ", plus rebuilds of: #{Enum.join(names, ", ")}"
              end
          end

        [Helpers.finding(__MODULE__, severity, message, migration, line, relations: [qualified])]
      end
    end
  end

  defp crdb_judge(qualified, col, line, migration, catalog) do
    bare = qualified |> String.split(".") |> List.last()

    indexed? = indexes_on(catalog, bare, col) != []
    constrained? = has_constraint_on?(catalog, bare, col)
    generated_stored? = is_generated_stored?(catalog, bare, col)

    rejected? = indexed? or constrained? or generated_stored?

    case rejected? and CRDB.judge(:alter_column_type_indexed, catalog.version_num) do
      {:rejected, note} ->
        [
          Helpers.finding(__MODULE__, :error, "#{qualified}.#{col}: #{note}", migration, line,
            relations: [qualified],
            engine: :cockroachdb
          )
        ]

      _ ->
        [
          Helpers.finding(
            __MODULE__,
            :warning,
            "#{qualified}.#{col}: ALTER COLUMN TYPE on CockroachDB is restricted " <>
              "(cannot run inside a transaction with other statements)",
            migration,
            line,
            relations: [qualified],
            engine: :cockroachdb
          )
        ]
    end
  end

  defp has_constraint_on?(catalog, table, col) do
    case Catalog.table(catalog, table) do
      nil ->
        false

      t ->
        Enum.any?(t.constraints, fn c ->
          Enum.member?(c.columns || [], col)
        end)
    end
  end

  defp is_generated_stored?(catalog, table, col) do
    case Catalog.column(catalog, table, col) do
      nil -> false
      c -> c.generated == :stored
    end
  end

  defp indexes_on(catalog, table, col) do
    case Catalog.table(catalog, table) do
      nil ->
        []

      t ->
        for idx <- t.indexes,
            Enum.any?(idx.keys, &match?(%{kind: :column, name: ^col}, &1)),
            do: idx.name
    end
  end

  defp format_type(:string, opts), do: "character varying(#{Keyword.get(opts, :size, 255)})"

  defp format_type(:decimal, opts) do
    precision = Keyword.get(opts, :precision)
    scale = Keyword.get(opts, :scale)

    case {precision, scale} do
      {p, s} when is_integer(p) and is_integer(s) -> "numeric(#{p},#{s})"
      {p, _} when is_integer(p) -> "numeric(#{p})"
      _ -> "numeric"
    end
  end

  defp format_type(:numeric, opts) do
    precision = Keyword.get(opts, :precision)
    scale = Keyword.get(opts, :scale)

    case {precision, scale} do
      {p, s} when is_integer(p) and is_integer(s) -> "numeric(#{p},#{s})"
      {p, _} when is_integer(p) -> "numeric(#{p})"
      _ -> "numeric"
    end
  end

  defp format_type(type, _opts) when is_atom(type),
    do: Map.get(@dsl_types, type)

  defp format_type({:references, _, _}, _opts), do: "bigint"

  # Unmappable types: return nil to suppress false positives
  defp format_type(_other, _opts), do: nil

  # The in-code binary-coercible table: varchar(n)->varchar(m>=n), varchar->text.
  defp binary_coercible?(current, new_type) do
    case {parse_varchar(current), parse_varchar(new_type)} do
      {{:varchar, n}, {:varchar, m}} -> m >= n
      {{:varchar, _}, _} -> new_type == "text"
      _ -> false
    end
  end

  defp parse_varchar("character varying(" <> rest),
    do: {:varchar, rest |> String.trim_trailing(")") |> String.to_integer()}

  defp parse_varchar("character varying"), do: {:varchar, 0}
  defp parse_varchar(_), do: nil
end
