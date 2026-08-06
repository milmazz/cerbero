defmodule Cerbero.SeverityTest do
  use ExUnit.Case, async: true

  alias Cerbero.Severity

  setup do
    {:ok, config} = Cerbero.Config.load("nonexistent")
    %{config: config}
  end

  # {lock, cost, scale, traffic, multiplier, expected}
  @cases [
    # full_scan/rewrite under write-blocking lock: tiers by rows/bytes
    {:share, :full_scan, {:rows, 412_000_000, 219_902_325_555}, :cold, 1.0, :error},
    {:access_exclusive, :rewrite, {:rows, 500_000, 0}, :cold, 1.0, :warning},
    {:access_exclusive, :rewrite, {:rows, 50_000, 2_000_000_000}, :cold, 1.0, :error},
    {:share, :full_scan, {:rows, 5_000, 8_192}, :cold, 1.0, :info},
    # headroom multiplier: 600k rows judged at 0.5x thresholds -> error tier
    {:share, :full_scan, {:rows, 600_000, 0}, :cold, 0.5, :error},
    # unknown scale = unbounded, never small: warning floor
    {:share, :full_scan, :unknown, :unknown, 1.0, :warning},
    # born-this-deploy zero scale under a scan: nothing to scan
    {:share, :full_scan, :zero, :cold, 1.0, :none},
    # metadata-only under AEL: traffic OR rows gates warning; never silent
    {:access_exclusive, :metadata_only, {:rows, 10_000, 8_192}, :hot, 1.0, :warning},
    {:access_exclusive, :metadata_only, {:rows, 200_000, 8_192}, :cold, 1.0, :warning},
    {:access_exclusive, :metadata_only, {:rows, 10, 8_192}, :cold, 1.0, :info},
    {:access_exclusive, :metadata_only, :zero, :cold, 1.0, :info},
    # non-blocking lock, metadata cost: silent
    {:share_update_exclusive, :metadata_only, {:rows, 412_000_000, 0}, :hot, 1.0, :none},
    # non-blocking full scan (CIC, VALIDATE): cost note at scale, info
    {:share_update_exclusive, :full_scan, {:rows, 412_000_000, 0}, :cold, 1.0, :info},
    {:share_update_exclusive, :full_scan, {:rows, 5_000, 0}, :cold, 1.0, :none}
  ]

  test "severity table", %{config: config} do
    for {lock, cost, scale, traffic, mult, expected} <- @cases do
      assert Severity.assess(lock, cost, scale, traffic, config, mult) == expected,
             "#{inspect({lock, cost, scale, traffic, mult})} expected #{expected}"
    end
  end

  test "ordering helper" do
    assert Cerbero.Finding.at_least?(:error, :warning)
    assert Cerbero.Finding.at_least?(:warning, :warning)
    refute Cerbero.Finding.at_least?(:info, :warning)
  end
end
