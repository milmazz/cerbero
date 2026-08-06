defmodule Cerbero.Check.CRDBTransactionalDDL do
  @moduledoc "Rule 7: CockroachDB transactional schema-change restrictions."
  @behaviour Cerbero.Check

  alias Cerbero.Check.Helpers
  alias Cerbero.DDL.{CRDB, Effects}

  @impl true
  def id, do: :crdb_transactional_ddl

  @dml_classes [:dml_update, :dml_delete, :dml_insert_select]

  @impl true
  def run(migration, catalog, _config) do
    if catalog.engine != :cockroachdb or migration.attrs.disable_ddl_transaction do
      []
    else
      effects =
        migration.operations
        |> Enum.flat_map(&Effects.derive(&1, catalog.engine, catalog.version_num))
        |> Enum.reject(&(&1.class in @dml_classes or &1.class == :create_table))

      type_changes = Enum.filter(effects, &(&1.class == :alter_column_type))

      cond do
        type_changes != [] and length(effects) > 1 ->
          {_, note} = CRDB.judge(:alter_column_type_in_txn, catalog.version_num)

          for effect <- type_changes do
            Helpers.finding(
              __MODULE__,
              :error,
              note <>
                "; move the type change to its own migration " <>
                "with @disable_ddl_transaction true",
              migration,
              effect.line,
              engine: :cockroachdb
            )
          end

        length(effects) > 1 ->
          {_, note} = CRDB.judge(:multiple_ddl_in_txn, catalog.version_num)
          [first | _] = effects

          [
            Helpers.finding(
              __MODULE__,
              :warning,
              "#{length(effects)} schema changes in one transactional migration on CockroachDB: #{note}. " <>
                "Split them or set @disable_ddl_transaction true",
              migration,
              first.line,
              engine: :cockroachdb
            )
          ]

        true ->
          []
      end
    end
  end
end
