defmodule Cerbero.Snapshot.Bucketing do
  @moduledoc """
  Opt-in `precision: :order_of_magnitude` export mode: buckets counts and
  bytes to their power-of-ten floor so a committed snapshot does not reveal
  exact business metrics (a `subscriptions` row count is a revenue proxy).

  The default severity tiers (100k/1M rows) are powers of ten, so comparing
  bucket floors against them preserves verdicts; message precision degrades
  ("~100M rows"). The bytes tier default (1 GiB) is not a power of ten —
  teams using this mode should prefer a power-of-ten `bytes_error`.

  Non-positive values (0, and the PG >= 14 never-analyzed `-1.0` sentinel)
  and nil pass through untouched.
  """

  import Kernel, except: [apply: 1]

  @table_fields ~w(reltuples relpages n_live_tup seq_scan idx_scan
                   n_tup_ins n_tup_upd n_tup_del heap_bytes total_bytes)

  @spec bucket(number() | nil) :: number() | nil
  def bucket(nil), do: nil
  def bucket(n) when is_number(n) and n <= 0, do: n

  def bucket(n) when is_integer(n) do
    Integer.pow(10, floor(:math.log10(n)))
  end

  def bucket(n) when is_float(n) do
    :math.pow(10, floor(:math.log10(n)))
  end

  @doc """
  The exporter's entry point: stamps the raw map's `"precision"` field and,
  in `:order_of_magnitude` mode, buckets every count/byte field.
  """
  @spec finalize(map(), :exact | :order_of_magnitude) :: map()
  def finalize(raw, :exact), do: Map.put(raw, "precision", "exact")

  def finalize(raw, :order_of_magnitude) do
    raw |> __MODULE__.apply() |> Map.put("precision", "order_of_magnitude")
  end

  @doc "Buckets every count/byte field of a raw (string-keyed) snapshot map."
  @spec apply(map()) :: map()
  def apply(%{"tables" => tables} = raw) when is_list(tables) do
    %{raw | "tables" => Enum.map(tables, &bucket_table/1)}
  end

  defp bucket_table(table) do
    table
    |> bucket_fields(@table_fields)
    |> Map.update("indexes", [], fn indexes ->
      Enum.map(indexes, &bucket_fields(&1, ["bytes"]))
    end)
  end

  defp bucket_fields(map, fields) do
    Enum.reduce(fields, map, fn field, acc ->
      case acc do
        %{^field => value} -> Map.put(acc, field, bucket(value))
        _ -> acc
      end
    end)
  end
end
