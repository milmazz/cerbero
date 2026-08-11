defmodule Cerbero.Catalog do
  @moduledoc """
  The queryable in-memory model the checks run against. Row-estimate
  policy: max(reltuples, n_live_tup) when reltuples >= 0, else n_live_tup;
  partitioned parents are the sum of their partitions, never the parent
  row; unknown scale is unbounded, never small.
  """

  import Kernel, except: [apply: 2]

  alias Cerbero.Config
  alias Cerbero.Migration
  alias Cerbero.Operation, as: Op
  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Staleness
  alias Cerbero.Snapshot.Table
  alias Cerbero.SQL.Classifier.Classified

  defstruct engine: :postgres,
            version_num: 150_000,
            tables: %{},
            partitions: %{},
            scale_mode: :exact,
            multiplier: 1.0,
            born: MapSet.new(),
            backfilled: MapSet.new(),
            source: :snapshot,
            collected_at: nil,
            stats_reset: nil,
            standby: false,
            stats_provenance: :primary

  @type t :: %__MODULE__{}

  @spec from_snapshot(Snapshot.t(), Staleness.t()) :: t()
  def from_snapshot(%Snapshot{} = s, %Staleness{} = staleness) do
    tables = Map.new(s.tables, fn t -> {"#{t.schema}.#{t.name}", t} end)

    %__MODULE__{
      engine: s.engine.name,
      version_num: s.engine.version_num,
      tables: tables,
      partitions: partitions_index(tables),
      scale_mode: staleness.scale_mode,
      multiplier: staleness.threshold_multiplier,
      source: :snapshot,
      collected_at: s.collected_at,
      stats_reset: s.stats_reset,
      standby: s.standby,
      stats_provenance: s.stats_provenance
    }
  end

  # parent qname -> [partition qname], built once at load: scale/2 on a
  # partitioned parent previously re-scanned every table in the catalog on
  # every call. Maintained through the overlay by the DropTable clause of
  # apply/2; creates never need an update because overlay-born tables
  # always carry partition_of nil (born_table/3) — partition_sum/2 guards
  # against exactly that create-over-a-partition's-name case.
  defp partitions_index(tables) do
    tables
    |> Enum.filter(fn {_qname, t} -> is_binary(t.partition_of) end)
    |> Enum.group_by(fn {_qname, t} -> t.partition_of end, fn {qname, _t} -> qname end)
  end

  @spec empty(:postgres | :cockroachdb, integer()) :: t()
  def empty(engine \\ :postgres, version_num \\ 150_000) do
    %__MODULE__{engine: engine, version_num: version_num, source: :replay, scale_mode: :unbounded}
  end

  @spec qualify(String.t()) :: String.t()
  def qualify(name) do
    if String.contains?(name, "."), do: name, else: "public." <> name
  end

  @spec table(t(), String.t()) :: Table.t() | nil
  def table(%__MODULE__{tables: tables}, name), do: Map.get(tables, qualify(name))

  @spec known?(t(), String.t()) :: boolean()
  def known?(cat, name), do: table(cat, name) != nil

  @spec born?(t(), String.t()) :: boolean()
  def born?(%__MODULE__{born: born}, name), do: MapSet.member?(born, qualify(name))

  @spec backfilled?(t(), String.t()) :: boolean()
  def backfilled?(%__MODULE__{backfilled: b}, name), do: MapSet.member?(b, qualify(name))

  @doc "Created by the pending set and never backfilled — still empty by construction, safe to silence."
  @spec born_empty?(t(), String.t()) :: boolean()
  def born_empty?(cat, name), do: born?(cat, name) and not backfilled?(cat, name)

  @spec scale(t(), String.t()) :: {:rows, non_neg_integer(), non_neg_integer()} | :zero | :unknown
  def scale(%__MODULE__{} = cat, name) do
    cond do
      born?(cat, name) and backfilled?(cat, name) ->
        :unknown

      born?(cat, name) ->
        :zero

      cat.scale_mode == :unbounded ->
        :unknown

      true ->
        case table(cat, name) do
          nil ->
            :unknown

          %Table{partitioned: true} ->
            partition_sum(cat, qualify(name))

          %Table{} = t ->
            case row_estimate(t) do
              :unknown -> :unknown
              rows -> {:rows, rows, t.heap_bytes || 0}
            end
        end
    end
  end

  defp partition_sum(cat, parent) do
    # Each indexed member is re-checked against the live tables map: a
    # pending CreateTable over an existing partition's name replaces the
    # table with an overlay-born one (partition_of nil) without touching
    # the index, and such a table must not keep contributing the old
    # partition's rows — the partition_of guard preserves the pre-index
    # Enum.filter semantics exactly.
    partitions =
      for qname <- Map.get(cat.partitions, parent, []),
          %Table{partition_of: ^parent} = t <- [Map.get(cat.tables, qname)],
          do: t

    case partitions do
      [] ->
        :unknown

      _ ->
        # A partition whose own scale is unknown must not silently
        # contribute 0 to the sum — that would let one instrumented
        # partition mask an uninstrumented sibling. Unknown poisons the
        # whole parent's scale to :unknown (unbounded), never small.
        Enum.reduce_while(partitions, {:rows, 0, 0}, fn t, {:rows, rows, bytes} ->
          case row_estimate(t) do
            :unknown -> {:halt, :unknown}
            r -> {:cont, {:rows, rows + r, bytes + (t.heap_bytes || 0)}}
          end
        end)
    end
  end

  # CRDB leaves both reltuples and n_live_tup NULL when the engine has
  # collected no row-statistics for a table yet (see the exporter's
  # crdb_row_counts wiring). When BOTH are unknown, the table's scale is
  # :unknown — never a fabricated 0, which would let every scale rule
  # silently pass on an uninstrumented CRDB table.
  defp row_estimate(%Table{reltuples: rt, n_live_tup: nlt}) do
    cond do
      is_number(rt) and rt >= 0 -> max(trunc(rt), nlt || 0)
      is_integer(nlt) -> nlt
      true -> :unknown
    end
  end

  @spec traffic(t(), String.t(), Config.t()) :: :hot | :cold | :unknown
  def traffic(%__MODULE__{} = cat, name, %Config{} = config) do
    with false <- cat.standby,
         %Table{} = t <- table(cat, name),
         %DateTime{} = reset <- cat.stats_reset,
         %DateTime{} = collected <- cat.collected_at,
         seconds when seconds > 0 <- DateTime.diff(collected, reset, :second) do
      ops =
        (t.seq_scan || 0) + (t.idx_scan || 0) + (t.n_tup_ins || 0) + (t.n_tup_upd || 0) +
          (t.n_tup_del || 0)

      if ops / seconds >= config.hot_ops_per_sec, do: :hot, else: :cold
    else
      _ -> :unknown
    end
  end

  @spec column(t(), String.t(), String.t()) :: map() | nil
  def column(cat, table_name, column_name) do
    case table(cat, table_name) do
      nil -> nil
      %Table{columns: cols} -> Enum.find(cols, &(&1.name == column_name))
    end
  end

  @spec has_index_leading_on?(t(), String.t(), String.t()) :: boolean()
  def has_index_leading_on?(cat, table_name, column_name) do
    case table(cat, table_name) do
      nil ->
        false

      %Table{indexes: indexes} ->
        Enum.any?(indexes, fn idx ->
          match?([%{kind: :column, name: ^column_name} | _], idx.keys)
        end)
    end
  end

  @spec validated_not_null_check?(t(), String.t(), String.t()) :: boolean()
  def validated_not_null_check?(cat, table_name, column_name) do
    case table(cat, table_name) do
      nil ->
        false

      %Table{constraints: cons} ->
        Enum.any?(
          cons,
          &(&1.type == :check and &1.validated and &1.is_not_null_check_on == column_name)
        )
    end
  end

  @spec apply_migration(t(), Migration.t()) :: t()
  def apply_migration(cat, %Migration{operations: ops}), do: Enum.reduce(ops, cat, &apply(&2, &1))

  @spec apply(t(), struct()) :: t()
  def apply(cat, %Op.CreateTable{table: name, columns: columns}) do
    born_table(cat, name, Enum.map(columns, &overlay_column/1))
  end

  def apply(cat, %Op.DropTable{table: name}) do
    qname = qualify(name)

    # The dropped table leaves the partitions index on both sides: as a
    # parent key (if it was partitioned) and as a member of its own
    # parent's list (if it was a partition). Map.replace_lazy so an absent
    # parent key is not conjured into an empty list — partition_sum/2
    # treats a missing key and an all-members-dropped list the same
    # (:unknown), but the index should not grow keys for tables that were
    # never parents.
    partitions =
      case Map.get(cat.tables, qname) do
        %Table{partition_of: parent} when is_binary(parent) ->
          cat.partitions
          |> Map.delete(qname)
          |> Map.replace_lazy(parent, &List.delete(&1, qname))

        _ ->
          Map.delete(cat.partitions, qname)
      end

    %{
      cat
      | tables: Map.delete(cat.tables, qname),
        partitions: partitions,
        born: MapSet.delete(cat.born, qname),
        backfilled: MapSet.delete(cat.backfilled, qname)
    }
  end

  def apply(cat, %Op.AlterTable{table: name, ops: alter_ops}) do
    update_table(cat, name, fn t -> Enum.reduce(alter_ops, t, &apply_alter/2) end)
  end

  def apply(cat, %Op.CreateIndex{table: name, keys: keys, unique: unique}) do
    idx = %{
      name: "#{name}_#{Enum.map_join(keys, "_", &to_string/1)}_index",
      unique: unique,
      primary: false,
      valid: true,
      method: "btree",
      partial: false,
      bytes: 0,
      keys:
        Enum.map(keys, fn
          :expression -> %{kind: :expression}
          k -> %{kind: :column, name: k}
        end)
    }

    update_table(cat, name, fn t -> %{t | indexes: t.indexes ++ [idx]} end)
  end

  def apply(cat, %Op.DropIndex{}), do: cat

  def apply(cat, %Op.CreateConstraint{table: name, name: cname, check: check, validate: validate}) do
    is_nn =
      case check && Regex.run(~r/^\s*(\w+)\s+is\s+not\s+null\s*$/i, check) do
        [_, col] -> col
        _ -> nil
      end

    con = make_check_constraint(cname, validate, [], is_nn)

    update_table(cat, name, fn t -> %{t | constraints: t.constraints ++ [con]} end)
  end

  def apply(cat, %Op.RawSQL{classified: classified}), do: Enum.reduce(classified, cat, &apply_sql(&2, &1))

  def apply(cat, %Op.RenameOp{}), do: cat
  def apply(cat, %Op.Unknown{}), do: cat

  defp apply_sql(cat, %Classified{class: :create_table, table: name}), do: born_table(cat, name, [])

  defp apply_sql(cat, %Classified{class: :drop_table, table: name}), do: apply(cat, %Op.DropTable{table: name})

  defp apply_sql(cat, %Classified{
         class: :add_check_is_not_null,
         table: name,
         column: col,
         constraint: cname,
         not_valid: nv
       }) do
    con = make_check_constraint(cname, not nv, [col], col)

    update_table(cat, name, fn t -> %{t | constraints: t.constraints ++ [con]} end)
  end

  defp apply_sql(cat, %Classified{class: :validate_constraint, table: name, constraint: cname}) do
    update_table(cat, name, fn t ->
      %{
        t
        | constraints:
            Enum.map(t.constraints, fn con ->
              if con.name == cname, do: %{con | validated: true}, else: con
            end)
      }
    end)
  end

  defp apply_sql(cat, %Classified{class: :set_not_null, table: name, column: col}) do
    update_column(cat, name, col, &%{&1 | not_null: true})
  end

  defp apply_sql(cat, %Classified{class: :add_column, table: name, column: col}) do
    update_table(cat, name, fn t ->
      %{
        t
        | columns:
            t.columns ++
              [
                %{
                  name: col,
                  type: "unknown",
                  not_null: false,
                  identity: false,
                  generated: nil,
                  default: nil
                }
              ]
      }
    end)
  end

  defp apply_sql(cat, %Classified{class: :drop_column, table: name, column: col}) do
    update_table(cat, name, fn t -> %{t | columns: Enum.reject(t.columns, &(&1.name == col))} end)
  end

  defp apply_sql(cat, %Classified{class: :create_index, table: name}) when is_binary(name) do
    update_table(cat, name, fn t ->
      idx = %{
        name: "raw_sql_index_#{length(t.indexes)}",
        unique: false,
        primary: false,
        valid: true,
        method: "btree",
        partial: false,
        bytes: 0,
        keys: [%{kind: :expression}]
      }

      %{t | indexes: t.indexes ++ [idx]}
    end)
  end

  defp apply_sql(cat, %Classified{class: dml, table: name})
       when dml in [:update, :delete, :insert_select] and is_binary(name) do
    %{cat | backfilled: MapSet.put(cat.backfilled, qualify(name))}
  end

  defp apply_sql(cat, %Classified{}), do: cat

  defp apply_alter({:add_column, name, type, opts}, t) do
    %{t | columns: t.columns ++ [overlay_column(%{name: name, type: type, opts: opts})]}
  end

  defp apply_alter({:modify_column, name, type, opts}, t) do
    %{
      t
      | columns:
          Enum.map(t.columns, fn col ->
            if col.name == name do
              col = if type, do: %{col | type: overlay_type(type)}, else: col

              case Keyword.get(opts, :null) do
                false -> %{col | not_null: true}
                true -> %{col | not_null: false}
                nil -> col
              end
            else
              col
            end
          end)
    }
  end

  defp apply_alter({:remove_column, name}, t), do: %{t | columns: Enum.reject(t.columns, &(&1.name == name))}

  defp apply_alter(_other, t), do: t

  defp born_table(cat, name, columns) do
    qname = qualify(name)
    [schema, bare] = String.split(qname, ".", parts: 2)

    t = %Table{
      schema: schema,
      name: bare,
      partitioned: false,
      partition_of: nil,
      reltuples: 0.0,
      relpages: 0,
      n_live_tup: 0,
      last_analyze: nil,
      last_autoanalyze: nil,
      seq_scan: 0,
      idx_scan: 0,
      n_tup_ins: 0,
      n_tup_upd: 0,
      n_tup_del: 0,
      heap_bytes: 0,
      total_bytes: 0,
      columns: columns,
      indexes: [],
      constraints: []
    }

    %{cat | tables: Map.put(cat.tables, qname, t), born: MapSet.put(cat.born, qname)}
  end

  defp update_table(cat, name, fun) do
    case table(cat, name) do
      nil -> cat
      t -> %{cat | tables: Map.put(cat.tables, qualify(name), fun.(t))}
    end
  end

  defp update_column(cat, table_name, col_name, fun) do
    update_table(cat, table_name, fn t ->
      %{t | columns: Enum.map(t.columns, &if(&1.name == col_name, do: fun.(&1), else: &1))}
    end)
  end

  defp overlay_column(%{name: name, type: type, opts: opts}) do
    %{
      name: name,
      type: overlay_type(type),
      not_null: Keyword.get(opts, :null) == false,
      identity: false,
      generated: nil,
      default: overlay_default(opts)
    }
  end

  defp overlay_type({:references, _table, _opts}), do: "bigint"
  defp overlay_type(nil), do: "unknown"
  defp overlay_type(type), do: to_string_type(type)

  defp to_string_type(t) when is_atom(t), do: Atom.to_string(t)
  defp to_string_type(t) when is_binary(t), do: t
  defp to_string_type({:dynamic, s}), do: s

  defp overlay_default(opts) do
    case Keyword.fetch(opts, :default) do
      :error -> nil
      {:ok, {:fragment, _}} -> %{present: true, volatile: true, kind: :expression}
      {:ok, {:dynamic, _}} -> %{present: true, volatile: true, kind: :expression}
      {:ok, _literal} -> %{present: true, volatile: false, kind: :literal}
    end
  end

  defp make_check_constraint(name, validated, columns, is_not_null_check_on) do
    %{
      name: name,
      type: :check,
      columns: columns,
      validated: validated,
      references: nil,
      on_delete: nil,
      on_update: nil,
      is_not_null_check_on: is_not_null_check_on
    }
  end
end
