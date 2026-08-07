defmodule Cerbero.CLI.SnapshotTest do
  use ExUnit.Case, async: false

  alias Cerbero.CLI.Snapshot
  alias Cerbero.Snapshot, as: SnapshotArtifact

  @url "postgres://postgres:cerbero@localhost:54316/cerbero_test"

  defp run(argv) do
    {:ok, io} = StringIO.open("")
    code = Snapshot.run(argv, io: io)
    {_, output} = StringIO.contents(io)
    {code, output}
  end

  @tag :tmp_dir
  test "a bad .cerbero.exs config is exit 2, before attempting any export", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".cerbero.exs")
    File.write!(path, "[schemaz: [\"public\"]]")

    {code, output} = run(["--config", path, "--url", "postgres://unreachable/db"])

    assert code == 2
    assert output =~ "bad_config"
    assert output =~ "schemaz"
  end

  @tag :tmp_dir
  test "a valid config with a schemas list loads; falls through to the missing-source error", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, ".cerbero.exs")
    File.write!(path, ~s([schemas: ["public", "app"]]))

    {code, output} = run(["--config", path])

    assert code == 2
    assert output =~ "one of --url, --emit-sql, --from-file is required"
  end

  test "no --config given: missing default .cerbero.exs is not an error (defaults apply)" do
    {code, output} = run([])

    assert code == 2
    assert output =~ "one of --url, --emit-sql, --from-file is required"
  end

  test "an invalid --precision value is exit 2, before attempting any export" do
    {code, output} = run(["--precision", "fuzzy", "--url", "postgres://unreachable/db"])

    assert code == 2
    assert output =~ "invalid --precision"
  end

  @tag :postgres
  @tag :tmp_dir
  test "config.schemas is threaded through to the exporter, not hardcoded to public", %{
    tmp_dir: tmp_dir
  } do
    connect_opts =
      @url
      |> Ecto.Repo.Supervisor.parse_url()
      |> Keyword.delete(:scheme)
      |> Keyword.put(:pool_size, 1)

    {:ok, conn} = Postgrex.start_link(connect_opts)
    Postgrex.query!(conn, "CREATE SCHEMA IF NOT EXISTS cerbero_schemas_test", [])

    Postgrex.query!(
      conn,
      "CREATE TABLE IF NOT EXISTS cerbero_schemas_test.widgets (id bigint PRIMARY KEY)",
      []
    )

    config_path = Path.join(tmp_dir, "cerbero_schemas_config.exs")
    File.write!(config_path, ~s([schemas: ["public", "cerbero_schemas_test"]]))
    out_path = Path.join(tmp_dir, "cerbero_schemas_snapshot.json")

    {code, _output} = run(["--url", @url, "--config", config_path, "--out", out_path])
    assert code == 0

    assert {:ok, snapshot} = SnapshotArtifact.load(out_path)

    assert Enum.any?(
             snapshot.tables,
             &(&1.schema == "cerbero_schemas_test" and &1.name == "widgets")
           )

    # Control: the default config (schemas: ["public"]) must NOT pick it up.
    default_config_path = Path.join(tmp_dir, "cerbero_default_schemas_config.exs")
    File.write!(default_config_path, "[]")
    default_out_path = Path.join(tmp_dir, "cerbero_default_schemas_snapshot.json")

    {0, _} = run(["--url", @url, "--config", default_config_path, "--out", default_out_path])
    assert {:ok, default_snapshot} = SnapshotArtifact.load(default_out_path)
    refute Enum.any?(default_snapshot.tables, &(&1.schema == "cerbero_schemas_test"))
  end
end
