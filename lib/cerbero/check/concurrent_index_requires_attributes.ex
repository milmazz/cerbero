defmodule Cerbero.Check.ConcurrentIndexRequiresAttributes do
  @moduledoc """
  Rule 10: concurrently: true without both @disable_ddl_transaction and
  @disable_migration_lock fails at deploy time and leaves an invalid
  index. Rule 1's own advice must not produce that.
  """
  @behaviour Cerbero.Check

  alias Cerbero.Check.Helpers
  alias Cerbero.Operation, as: Op

  @impl true
  def id, do: :concurrent_index_requires_attributes

  @impl true
  def run(migration, _catalog, _config) do
    %{disable_ddl_transaction: ddl, disable_migration_lock: lock} = migration.attrs

    if ddl and lock do
      []
    else
      for %Op.CreateIndex{concurrently: true, line: line} <- migration.operations do
        Helpers.finding(
          __MODULE__,
          :error,
          "concurrently: true requires both @disable_ddl_transaction true and " <>
            "@disable_migration_lock true; without them the deploy fails and leaves an invalid index",
          migration,
          line
        )
      end
    end
  end
end
