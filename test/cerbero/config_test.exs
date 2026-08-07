defmodule Cerbero.ConfigTest.NoopCheck do
  @behaviour Cerbero.Check

  @impl true
  def id, do: :noop_check

  @impl true
  def run(_migration, _catalog, _config), do: []
end

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
    assert c.extra_checks == []
    assert c.precision == :exact
    assert c.schemas == ["public"]
    assert c.migrations_paths == ["priv/repo/migrations"]
    assert c.snapshot_path == "priv/repo/cerbero_snapshot.json"
  end

  @tag :tmp_dir
  test "loads overrides from a .cerbero.exs keyword list", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".cerbero.exs")
    File.write!(path, "[rows_error: 5_000_000, lock_timeout_attested: true]")
    assert {:ok, %Config{rows_error: 5_000_000, lock_timeout_attested: true}} = Config.load(path)
  end

  @tag :tmp_dir
  test "extra_checks accepts modules implementing the Cerbero.Check behaviour", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, ".cerbero.exs")
    File.write!(path, "[extra_checks: [Cerbero.ConfigTest.NoopCheck]]")

    assert {:ok, %Config{extra_checks: [Cerbero.ConfigTest.NoopCheck]}} = Config.load(path)
  end

  @tag :tmp_dir
  test "extra_checks entry not implementing the behaviour is a bad_config error", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, ".cerbero.exs")
    File.write!(path, "[extra_checks: [String]]")

    assert {:error, {:bad_config, msg}} = Config.load(path)
    assert msg =~ "String"
    assert msg =~ "Cerbero.Check"
  end

  @tag :tmp_dir
  test "extra_checks that is not a list is a bad_config error", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".cerbero.exs")
    File.write!(path, "[extra_checks: Cerbero.ConfigTest.NoopCheck]")

    assert {:error, {:bad_config, msg}} = Config.load(path)
    assert msg =~ "list"
  end

  @tag :tmp_dir
  test "unknown keys are a bad_config error, not a crash", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".cerbero.exs")
    File.write!(path, "[rows_eror: 5]")
    assert {:error, {:bad_config, msg}} = Config.load(path)
    assert msg =~ "rows_eror"
  end
end
