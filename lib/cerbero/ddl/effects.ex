defmodule Cerbero.DDL.Effects do
  @moduledoc "Operation -> [Effect]. Total: unmapped classes get the conservative default."

  alias Cerbero.DDL.{Effect, Locks}
  alias Cerbero.Operation, as: Op
  alias Cerbero.SQL.Classifier.Classified

  @doc "Every class this module can emit — checked against Locks by the totality test."
  def classes_emitted do
    ~w(create_table create_index create_index_concurrently drop_index drop_index_concurrently
       add_column_constant_default add_column_volatile_default add_column_generated_stored
       add_primary_key add_unique set_not_null add_check add_check_not_valid validate_check
       add_foreign_key add_foreign_key_not_valid validate_foreign_key alter_column_type
       truncate reindex reindex_concurrently drop_column drop_table rename set_default
       dml_update dml_delete dml_insert_select)a
  end

  @spec derive(struct(), :postgres | :cockroachdb, integer()) :: [Effect.t()]
  def derive(op, engine, version_num) do
    op
    |> classify()
    |> Enum.map(fn {class, relations} ->
      case Locks.entry(class, engine, version_num) do
        {lock, cost} ->
          %Effect{
            class: class,
            lock: lock,
            cost: cost,
            relations: relations,
            notes: [version_note(engine, version_num)],
            line: line_of(op)
          }

        :unmapped ->
          conservative(class, relations, engine, version_num, op)
      end
    end)
  end

  defp conservative(class, relations, engine, version_num, op) do
    %Effect{
      class: class,
      lock: :access_exclusive,
      cost: :rewrite,
      relations: relations,
      unmapped: true,
      notes: [version_note(engine, version_num)],
      line: line_of(op)
    }
  end

  defp line_of(%{line: line}), do: line
  defp line_of(_), do: nil

  defp version_note(:postgres, version_num),
    do:
      "assuming PG #{div(version_num, 10_000)} per snapshot; version-conditional verdicts may change"

  defp version_note(:cockroachdb, version_num),
    do: "assuming CockroachDB #{version_num} per snapshot"

  # -- classification of operations into lock-table classes -----------------

  defp classify(%Op.CreateTable{table: t}), do: [{:create_table, [target: t]}]
  defp classify(%Op.DropTable{table: t}), do: [{:drop_table, [target: t]}]
  defp classify(%Op.RenameOp{table: t}), do: [{:rename, [target: t]}]

  defp classify(%Op.CreateIndex{table: t, concurrently: true}),
    do: [{:create_index_concurrently, [target: t]}]

  defp classify(%Op.CreateIndex{table: t, unique: true, concurrently: false}),
    do: [{:add_unique, [target: t]}]

  defp classify(%Op.CreateIndex{table: t}), do: [{:create_index, [target: t]}]

  defp classify(%Op.DropIndex{table: t, concurrently: true}),
    do: [{:drop_index_concurrently, [target: t]}]

  defp classify(%Op.DropIndex{table: t}), do: [{:drop_index, [target: t]}]

  defp classify(%Op.CreateConstraint{table: t, validate: false}),
    do: [{:add_check_not_valid, [target: t]}]

  defp classify(%Op.CreateConstraint{table: t}), do: [{:add_check, [target: t]}]

  defp classify(%Op.AlterTable{table: t, ops: ops}), do: Enum.flat_map(ops, &alter_class(&1, t))

  defp classify(%Op.RawSQL{classified: classified}), do: Enum.flat_map(classified, &sql_class/1)

  defp classify(%Op.Unknown{}), do: [{:unknown_operation, []}]

  defp classify(_other), do: [{:unknown_operation, []}]

  defp alter_class({:add_column, _name, {:references, ref, _}, opts}, t) do
    [
      {if(Keyword.get(opts, :validate, true),
         do: :add_foreign_key,
         else: :add_foreign_key_not_valid
       ), [target: t, referenced: ref]}
    ]
  end

  defp alter_class({:add_column, _name, _type, opts}, t), do: add_column_class(opts, t)

  defp alter_class({:modify_column, _name, type, opts}, t) do
    type_change = if type != nil, do: [{:alter_column_type, [target: t]}], else: []
    not_null = if Keyword.get(opts, :null) == false, do: [{:set_not_null, [target: t]}], else: []

    fk =
      case type do
        {:references, ref, _} -> [{:add_foreign_key, [target: t, referenced: ref]}]
        _ -> []
      end

    type_change ++ not_null ++ fk
  end

  defp alter_class({:remove_column, _name}, t), do: [{:drop_column, [target: t]}]
  defp alter_class({:unknown_alter, _}, _t), do: [{:unknown_operation, []}]

  defp add_column_class(opts, t) do
    cond do
      Keyword.has_key?(opts, :generated) ->
        [{:add_column_generated_stored, [target: t]}]

      match?({:fragment, _}, Keyword.get(opts, :default)) ->
        [{:add_column_volatile_default, [target: t]}]

      match?({:dynamic, _}, Keyword.get(opts, :default)) ->
        [{:add_column_volatile_default, [target: t]}]

      true ->
        [{:add_column_constant_default, [target: t]}]
    end
  end

  defp sql_class(%Classified{class: :create_index, concurrently: true, table: t}),
    do: [{:create_index_concurrently, [target: t]}]

  defp sql_class(%Classified{class: :create_index, unique: true, table: t}),
    do: [{:add_unique, [target: t]}]

  defp sql_class(%Classified{class: :create_index, table: t}), do: [{:create_index, [target: t]}]

  defp sql_class(%Classified{class: :drop_index, concurrently: c}),
    do: [{if(c, do: :drop_index_concurrently, else: :drop_index), []}]

  defp sql_class(%Classified{class: :add_check_is_not_null, not_valid: true, table: t}),
    do: [{:add_check_not_valid, [target: t]}]

  defp sql_class(%Classified{class: :add_check_is_not_null, table: t}),
    do: [{:add_check, [target: t]}]

  defp sql_class(%Classified{class: :add_check, not_valid: nv, table: t}),
    do: [{if(nv, do: :add_check_not_valid, else: :add_check), [target: t]}]

  defp sql_class(%Classified{class: :add_foreign_key, not_valid: nv, table: t}),
    do: [{if(nv, do: :add_foreign_key_not_valid, else: :add_foreign_key), [target: t]}]

  # VALIDATE CONSTRAINT: FK vs CHECK is resolved by the catalog in rules;
  # here we use the stricter FK profile (SUE on referencing + ROW SHARE on referenced).
  defp sql_class(%Classified{class: :validate_constraint, table: t}),
    do: [{:validate_foreign_key, [target: t]}]

  defp sql_class(%Classified{class: :set_not_null, table: t}), do: [{:set_not_null, [target: t]}]

  defp sql_class(%Classified{class: :alter_column_type, table: t}),
    do: [{:alter_column_type, [target: t]}]

  defp sql_class(%Classified{class: :add_column, table: t}),
    do: [{:add_column_constant_default, [target: t]}]

  defp sql_class(%Classified{class: :drop_column, table: t}), do: [{:drop_column, [target: t]}]
  defp sql_class(%Classified{class: :create_table, table: t}), do: [{:create_table, [target: t]}]
  defp sql_class(%Classified{class: :drop_table, table: t}), do: [{:drop_table, [target: t]}]
  defp sql_class(%Classified{class: :truncate, table: t}), do: [{:truncate, [target: t]}]

  defp sql_class(%Classified{class: :reindex, concurrently: c}),
    do: [{if(c, do: :reindex_concurrently, else: :reindex), []}]

  defp sql_class(%Classified{class: :update, table: t}), do: [{:dml_update, [target: t]}]
  defp sql_class(%Classified{class: :delete, table: t}), do: [{:dml_delete, [target: t]}]

  defp sql_class(%Classified{class: :insert_select, table: t}),
    do: [{:dml_insert_select, [target: t]}]

  defp sql_class(%Classified{class: :unknown}), do: [{:unclassified_sql, []}]
end
