defmodule Cerbero.Check.FKMissingIndex do
  @moduledoc "Rule 6: a new FK whose referencing column has no covering index in catalog ∪ overlay."
  @behaviour Cerbero.Check

  alias Cerbero.Catalog
  alias Cerbero.Check.Helpers
  alias Cerbero.Operation, as: Op

  @impl true
  def id, do: :fk_missing_index

  @impl true
  def run(migration, catalog, config) do
    same_migration_indexed =
      for %Op.CreateIndex{table: t, keys: [first | _]} <- migration.operations,
          into: MapSet.new(),
          do: {Catalog.qualify(t), to_string(first)}

    for op <- migration.operations,
        {table, col, ref, line} <- fk_columns(op),
        not covered?(catalog, table, col, same_migration_indexed),
        do: emit(table, col, ref, line, migration, config)
  end

  defp fk_columns(%Op.AlterTable{table: table, ops: ops, line: line}) do
    for {op_kind, col, {:references, ref, _opts}, _col_opts} <- normalize(ops),
        op_kind in [:add_column, :modify_column],
        do: {table, col, ref, line}
  end

  # FKs declared in the create block — the most common shape of the
  # missing-index mistake. A primary_key: true column is covered by the PK
  # index the create itself builds.
  defp fk_columns(%Op.CreateTable{table: table, columns: columns, line: line}) do
    for %{name: col, type: {:references, ref, _opts}, opts: col_opts} <- columns,
        Keyword.get(col_opts, :primary_key, false) != true,
        do: {table, col, ref, line}
  end

  defp fk_columns(_op), do: []

  defp normalize(ops) do
    Enum.map(ops, fn
      {kind, col, type, opts} -> {kind, col, type, opts}
      {kind, col} -> {kind, col, nil, []}
    end)
  end

  defp covered?(catalog, table, col, same_migration_indexed) do
    Catalog.has_index_leading_on?(catalog, table, col) or
      MapSet.member?(same_migration_indexed, {Catalog.qualify(table), col})
  end

  defp emit(table, col, ref, line, migration, _config) do
    q = Catalog.qualify(table)

    Helpers.finding(
      __MODULE__,
      :warning,
      "new foreign key #{q}.#{col} -> #{Catalog.qualify(ref)} has no covering index on #{col}; " <>
        "deletes/updates on the referenced table will sequential-scan #{q}",
      migration,
      line,
      relations: [q, Catalog.qualify(ref)]
    )
  end
end
