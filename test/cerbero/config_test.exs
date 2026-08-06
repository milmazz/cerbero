defmodule Cerbero.ConfigTest do
  use ExUnit.Case, async: true

  alias Cerbero.Config

  test "defaults match the design doc" do
    assert {:ok, %Config{} = c} = Config.load("nonexistent/.cerbero.exs")
    assert c.rows_warning == 100_000
    assert c.rows_error == 1_000_000
    assert c.bytes_error == 1_073_741_824
    assert c.hot_ops_per_sec == 1.0
    assert c.headroom_days == 14
    assert c.headroom_multiplier == 0.5
    assert c.stale_warn_days == 30
    assert c.stale_degrade_days == 90
    assert c.fail_on == :error
    assert c.skip_checks == []
    assert c.severity_overrides == %{}
    assert c.lock_timeout_attested == false
    assert c.strict_concurrent_index == false
    assert c.start_after == nil
    assert c.precision == :exact
    assert c.schemas == ["public"]
    assert c.migrations_paths == ["priv/repo/migrations"]
    assert c.snapshot_path == "priv/repo/cerbero_snapshot.json"
  end

  test "loads overrides from a .cerbero.exs keyword list" do
    path = Path.join(System.tmp_dir!(), ".cerbero.exs")
    File.write!(path, "[rows_error: 5_000_000, lock_timeout_attested: true]")
    assert {:ok, %Config{rows_error: 5_000_000, lock_timeout_attested: true}} = Config.load(path)
  end

  test "unknown keys are a bad_config error, not a crash" do
    path = Path.join(System.tmp_dir!(), ".cerbero_bad.exs")
    File.write!(path, "[rows_eror: 5]")
    assert {:error, {:bad_config, msg}} = Config.load(path)
    assert msg =~ "rows_eror"
  end
end
