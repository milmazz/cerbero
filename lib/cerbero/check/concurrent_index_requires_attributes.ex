defmodule Cerbero.Check.ConcurrentIndexRequiresAttributes do
  @moduledoc """
  Rule 10: concurrently: true without both @disable_ddl_transaction and
  @disable_migration_lock fails at deploy time and leaves an invalid
  index. Rule 1's own advice must not produce that.
  """
  @behaviour Cerbero.Check

  alias Cerbero.Check.Helpers
  alias Cerbero.Operation, as: Op
  alias Cerbero.SQL.Classifier.Classified

  @impl true
  def id, do: :concurrent_index_requires_attributes

  @impl true
  def run(migration, _catalog, _config) do
    %{disable_ddl_transaction: ddl, disable_migration_lock: lock} = migration.attrs

    if ddl and lock do
      []
    else
      for op <- migration.operations, line <- concurrent_index_lines(op) do
        Helpers.finding(
          __MODULE__,
          :error,
          "CREATE INDEX CONCURRENTLY requires both @disable_ddl_transaction true and " <>
            "@disable_migration_lock true; without them the deploy fails and leaves an invalid index",
          migration,
          line
        )
      end
    end
  end

  defp concurrent_index_lines(%Op.CreateIndex{concurrently: true, line: line}), do: [line]

  # Raw per-partition CIC is rule 1's own partitioned-parent remediation;
  # following that advice must not fail at deploy time either.
  defp concurrent_index_lines(%Op.RawSQL{classified: classified, line: line}) do
    for %Classified{class: :create_index, concurrently: true} <- classified, do: line
  end

  defp concurrent_index_lines(_op), do: []
end
