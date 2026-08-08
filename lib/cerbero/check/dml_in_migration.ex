defmodule Cerbero.Check.DMLInMigration do
  @moduledoc "Rule 9: classifier-detected UPDATE/DELETE/INSERT..SELECT against a table above threshold."
  @behaviour Cerbero.Check

  alias Cerbero.Catalog
  alias Cerbero.Check.Helpers
  alias Cerbero.Operation, as: Op
  alias Cerbero.SQL.Classifier.Classified

  @impl true
  def id, do: :dml_in_migration

  @impl true
  def run(migration, catalog, config) do
    for %Op.RawSQL{classified: classified, line: line} <- migration.operations,
        %Classified{class: kind, table: table} <- classified,
        kind in [:update, :delete, :insert_select],
        table != nil,
        risky?(catalog, kind, table, config),
        do: emit(kind, table, line, migration, catalog)
  end

  # For INSERT..SELECT the risk scales with the SOURCE size, which the
  # classifier does not extract — judge the (known-unknown) target and
  # let unknown scale stay unbounded.
  defp risky?(catalog, _kind, table, config) do
    case Catalog.scale(catalog, table) do
      {:rows, rows, _} -> rows >= config.rows_warning * catalog.multiplier
      :zero -> false
      :unknown -> true
    end
  end

  defp emit(kind, table, line, migration, catalog) do
    verb = kind |> Atom.to_string() |> String.upcase() |> String.replace("_", " ... ")

    Helpers.finding(
      __MODULE__,
      :warning,
      "#{verb} against #{Catalog.qualify(table)} (#{Helpers.describe_scale(catalog, table)}) runs as a " <>
        "single transaction inside the migration: long row locks, WAL burst, replication lag. " <>
        "Backfill in batches outside the migration instead",
      migration,
      line,
      relations: [Catalog.qualify(table)]
    )
  end
end
