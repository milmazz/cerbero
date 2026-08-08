defmodule Cerbero.Severity do
  @moduledoc """
  severity(lock, cost, scale, traffic, config, multiplier).

  Lock-queue damage tracks traffic, not table size; rewrite/scan damage
  tracks rows and bytes. The multiplier is staleness headroom (thresholds
  shrink as the snapshot ages). Unknown scale is unbounded, never small.
  An ACCESS EXCLUSIVE operation is never silent: the floor is :info.
  """

  alias Cerbero.Config

  @write_blocking [:access_exclusive, :share, :share_row_exclusive]

  @type scale :: {:rows, non_neg_integer(), non_neg_integer()} | :zero | :unknown
  @type traffic :: :hot | :cold | :unknown

  @spec assess(atom(), atom(), scale(), traffic(), Config.t(), float()) ::
          :error | :warning | :info | :none
  def assess(lock, cost, scale, traffic, config, multiplier \\ 1.0)

  # Scanning/rewriting under a write-blocking lock: the classic outage.
  def assess(lock, cost, scale, _traffic, %Config{} = c, mult)
      when lock in @write_blocking and cost in [:full_scan, :rewrite] do
    case scale do
      :zero ->
        if lock == :access_exclusive, do: :info, else: :none

      :unknown ->
        :warning

      {:rows, rows, bytes} ->
        cond do
          rows >= c.rows_error * mult or bytes >= c.bytes_error * mult -> :error
          rows >= c.rows_warning * mult -> :warning
          lock == :access_exclusive -> :info
          true -> :info
        end
    end
  end

  # Metadata-only under a write-blocking lock (AEL, or SHARE ROW EXCLUSIVE
  # e.g. ADD FOREIGN KEY ... NOT VALID): gate on traffic OR rows; never
  # silent. Not just :access_exclusive — SHARE and SHARE ROW EXCLUSIVE also
  # queue behind long-running transactions, same mechanism, same floor.
  def assess(lock, :metadata_only, scale, traffic, %Config{} = c, mult) when lock in @write_blocking do
    rows =
      case scale do
        {:rows, n, _} -> n
        _ -> 0
      end

    cond do
      traffic == :hot -> :warning
      scale == :unknown -> :warning
      rows >= c.rows_warning * mult -> :warning
      true -> :info
    end
  end

  # Non-blocking full scan (CIC, VALIDATE CONSTRAINT): resource cost note at scale.
  def assess(_lock, cost, {:rows, rows, bytes}, _traffic, %Config{} = c, mult) when cost in [:full_scan, :rewrite] do
    if rows >= c.rows_error * mult or bytes >= c.bytes_error * mult, do: :info, else: :none
  end

  def assess(_lock, cost, :unknown, _traffic, _c, _mult) when cost in [:full_scan, :rewrite], do: :info

  def assess(_lock, _cost, _scale, _traffic, _config, _mult), do: :none
end
