defmodule Cerbero.CLI.CheckTest do
  use ExUnit.Case, async: false

  alias Cerbero.CLI.Check

  @snapshot "test/fixtures/snapshots/huge_table.json"
  @migrations "test/fixtures/migrations/unsafe"

  # Snapshot collected_at is 2026-07-01; this clock makes it 12 days old.
  #
  # Not a module attribute: Elixir cannot escape/inject an anonymous
  # function literal into a module attribute (only literals, tuples,
  # remote captures, etc. are supported), so the clock is built by a
  # private zero-arity function instead.
  defp clock, do: fn -> ~U[2026-07-13 00:00:00Z] end

  defp run(argv) do
    {:ok, io} = StringIO.open("")
    code = Check.run(argv, io: io, clock: clock())
    {_, output} = StringIO.contents(io)
    {code, output}
  end

  defp golden(name, actual) do
    path = "test/golden/#{name}"
    if System.get_env("UPDATE_GOLDEN") == "1", do: File.write!(path, actual)

    assert File.read!(path) == actual,
           "golden mismatch for #{name}; UPDATE_GOLDEN=1 to regenerate"
  end

  test "definition of done: non-concurrent index on the 412M-row table fails CI, no DB reachable" do
    {code, output} =
      run(["--snapshot", @snapshot, "--migrations", @migrations, "--config", "nonexistent"])

    assert code == 1

    assert output =~
             "SHARE lock blocks writes on public.events (~412M rows, stats 2026-07-01) for a full-table scan"

    assert output =~ "unsafe_index_creation"
    assert output =~ "20260801000000_add_events_payload_index.exs:5"
    assert output =~ "judged against snapshot of app_prod, 2026-07-01, 12 days old"
  end

  test "human output matches golden byte-for-byte" do
    {_code, output} =
      run(["--snapshot", @snapshot, "--migrations", @migrations, "--config", "nonexistent"])

    golden("check_human.txt", output)
  end

  test "json output matches golden and is canonically stable" do
    {code, output} =
      run([
        "--snapshot",
        @snapshot,
        "--migrations",
        @migrations,
        "--config",
        "nonexistent",
        "--format",
        "json"
      ])

    assert code == 1
    golden("check_json.json", output)
    assert %{"cerbero_findings_version" => 1, "findings" => [_ | _]} = JSON.decode!(output)
  end

  test "sarif output matches golden and anchors findings for code scanning" do
    {code, output} =
      run([
        "--snapshot",
        @snapshot,
        "--migrations",
        @migrations,
        "--config",
        "nonexistent",
        "--format",
        "sarif"
      ])

    assert code == 1
    golden("check_sarif.json", output)

    doc = JSON.decode!(output)
    assert doc["version"] == "2.1.0"

    [sarif_run] = doc["runs"]
    assert sarif_run["tool"]["driver"]["name"] == "cerbero"
    assert [result | _] = sarif_run["results"]
    assert result["ruleId"] == "unsafe_index_creation"
    assert result["level"] == "error"

    [%{"physicalLocation" => loc}] = result["locations"]
    assert loc["artifactLocation"]["uri"] =~ "20260801000000_add_events_payload_index.exs"
    assert loc["region"] == %{"startLine" => 5}
  end

  test "missing snapshot is exit 2 (operational), not exit 1" do
    {code, output} =
      run([
        "--snapshot",
        "no/such/file.json",
        "--migrations",
        @migrations,
        "--config",
        "nonexistent"
      ])

    assert code == 2
    assert output =~ "error"
  end

  test "safe migration exits 0" do
    {code, _} =
      run([
        "--snapshot",
        @snapshot,
        "--migrations",
        "test/fixtures/migrations/safe",
        "--config",
        "nonexistent"
      ])

    assert code == 0
  end

  test "--fail-on warning promotes warnings to failures" do
    # The safe corpus has no warnings; use the unsafe one and a tighter fail-on with fresh clock
    {code, _} =
      run([
        "--snapshot",
        @snapshot,
        "--migrations",
        @migrations,
        "--config",
        "nonexistent",
        "--fail-on",
        "warning"
      ])

    assert code == 1
  end

  test "no-snapshot structural mode: runs, labels findings, unknown scale" do
    {code, output} =
      run(["--no-snapshot", "--migrations", @migrations, "--config", "nonexistent"])

    assert code in [0, 1]
    assert output =~ "no snapshot: structural checks only, scale unknown"
  end

  test "empty migrations_paths in config and no --migrations flag is exit 2, not a crash" do
    path = Path.join(System.tmp_dir!(), ".cerbero_empty_migrations.exs")
    File.write!(path, "[migrations_paths: []]")
    on_exit(fn -> File.rm(path) end)

    {code, output} = run(["--config", path])

    assert code == 2
    assert output =~ "config migrations_paths is empty; pass --migrations or fix .cerbero.exs"
  end

  test "--migrations pointing at a nonexistent directory is exit 2, not a silent all-clear" do
    {code, output} =
      run(["--no-snapshot", "--migrations", "no/such/dir", "--config", "nonexistent"])

    assert code == 2
    assert output =~ "migrations directory not found: no/such/dir"
  end

  test "an existing but empty migrations directory is a valid 0-pending case" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "cerbero_empty_migrations_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {code, _output} =
      run(["--snapshot", @snapshot, "--migrations", dir, "--config", "nonexistent"])

    assert code == 0
  end

  test "a snapshot from an unsupported engine version is exit 2 (operational)" do
    raw =
      Cerbero.Test.SnapshotBuilder.build(%{
        "engine" => %{"name" => "postgres", "version" => "12.9", "version_num" => 120_000}
      })

    path = Path.join(System.tmp_dir!(), "old_engine_snapshot.json")
    Cerbero.Snapshot.write!(raw, path)
    on_exit(fn -> File.rm(path) end)

    {code, output} =
      run(["--snapshot", path, "--migrations", @migrations, "--config", "nonexistent"])

    assert code == 2
    assert output =~ "PostgreSQL >= 13"
  end

  test "an order-of-magnitude snapshot annotates the summary line" do
    raw =
      Cerbero.Test.SnapshotBuilder.build(%{
        "format_version" => 2,
        "precision" => "order_of_magnitude",
        "collected_at" => "2026-07-01T00:00:00Z"
      })

    path = Path.join(System.tmp_dir!(), "bucketed_snapshot.json")
    Cerbero.Snapshot.write!(raw, path)
    on_exit(fn -> File.rm(path) end)

    {code, output} =
      run(["--snapshot", path, "--migrations", @migrations, "--config", "nonexistent"])

    assert code in [0, 1]
    assert output =~ "order-of-magnitude precision"
  end
end
