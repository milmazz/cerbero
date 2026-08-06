defmodule Cerbero.StalenessTest do
  use ExUnit.Case, async: true

  alias Cerbero.Snapshot.Staleness
  import Cerbero.Test.SnapshotBuilder

  defp assess(days_old) do
    snapshot = build_snapshot()
    now = DateTime.add(snapshot.collected_at, days_old, :day)
    {:ok, config} = Cerbero.Config.load("nonexistent")
    Staleness.assess(snapshot, now, config)
  end

  test "fresh snapshot: exact scale, no headroom" do
    assert %Staleness{age_days: 3, scale_mode: :exact, threshold_multiplier: 1.0} = assess(3)
  end

  test "past 14 days: headroom multiplier 0.5, still exact" do
    assert %Staleness{scale_mode: :exact, threshold_multiplier: 0.5} = assess(20)
  end

  test "past 90 days: scale degrades to unbounded" do
    assert %Staleness{scale_mode: :unbounded, threshold_multiplier: 0.5} = assess(91)
  end
end
