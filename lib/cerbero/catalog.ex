defmodule Cerbero.Catalog do
  @moduledoc """
  The queryable in-memory model the checks run against. Row-estimate
  policy: max(reltuples, n_live_tup) when reltuples >= 0, else n_live_tup;
  partitioned parents are the sum of their partitions, never the parent
  row; unknown scale is unbounded, never small.
  """

  alias Cerbero.{Config, Snapshot}
  alias Cerbero.Snapshot.{Staleness, Table}

  defstruct engine: :postgres,
            version_num: 150_000,
            tables: %{},
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
    %__MODULE__{
      engine: s.engine.name,
      version_num: s.engine.version_num,
      tables: Map.new(s.tables, fn t -> {"#{t.schema}.#{t.name}", t} end),
      scale_mode: staleness.scale_mode,
      multiplier: staleness.threshold_multiplier,
      source: :snapshot,
      collected_at: s.collected_at,
      stats_reset: s.stats_reset,
      standby: s.standby,
      stats_provenance: s.stats_provenance
    }
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
          nil -> :unknown
          %Table{partitioned: true} -> partition_sum(cat, qualify(name))
          %Table{} = t -> {:rows, row_estimate(t), t.heap_bytes || 0}
        end
    end
  end

  defp partition_sum(cat, parent) do
    cat.tables
    |> Map.values()
    |> Enum.filter(&(&1.partition_of == parent))
    |> Enum.reduce({:rows, 0, 0}, fn t, {:rows, rows, bytes} ->
      {:rows, rows + row_estimate(t), bytes + (t.heap_bytes || 0)}
    end)
  end

  defp row_estimate(%Table{reltuples: rt, n_live_tup: nlt}) do
    nlt = nlt || 0

    if is_number(rt) and rt >= 0 do
      max(trunc(rt), nlt)
    else
      nlt
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

  @spec constraint(t(), String.t(), String.t()) :: map() | nil
  def constraint(cat, table_name, constraint_name) do
    case table(cat, table_name) do
      nil -> nil
      %Table{constraints: cons} -> Enum.find(cons, &(&1.name == constraint_name))
    end
  end
end
