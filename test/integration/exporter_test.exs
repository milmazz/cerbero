defmodule Cerbero.Integration.ExporterTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Exporter

  @url "postgres://postgres:cerbero@localhost:54316/cerbero_test"
  # Same server, as seen from inside the pg16 container (used only when the
  # host has no `psql` and we shell out through `docker compose exec`).
  @container_url "postgres://postgres:cerbero@localhost:5432/cerbero_test"

  setup_all do
    # Postgrex.start_link/1 has no :url option (see Exporter.export/2) —
    # parse it the same way for this raw seeding connection.
    connect_opts =
      @url
      |> Ecto.Repo.Supervisor.parse_url()
      |> Keyword.delete(:scheme)
      |> Keyword.put(:pool_size, 1)

    {:ok, conn} = Postgrex.start_link(connect_opts)
    Postgrex.query!(conn, "DROP SCHEMA public CASCADE", [])
    Postgrex.query!(conn, "CREATE SCHEMA public", [])

    "test/integration/seed.sql"
    |> File.read!()
    |> String.trim()
    |> String.split(";\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&Postgrex.query!(conn, &1, []))

    :ok
  end

  @tag :tmp_dir
  test "export -> stamp -> write -> load -> strict decode round-trips", %{tmp_dir: tmp_dir} do
    assert {:ok, raw} = Exporter.export(@url)
    path = Path.join(tmp_dir, "live_snapshot.json")
    Snapshot.write!(raw, path)
    assert {:ok, %Snapshot{} = s} = Snapshot.load(path)
    assert s.engine.name == :postgres
    assert s.applied_migrations == ["20250101000000"]
  end

  test "every snapshot feature is captured" do
    {:ok, raw} = Exporter.export(@url)
    {:ok, s} = Snapshot.decode(Snapshot.stamp(raw))
    by_name = Map.new(s.tables, &{&1.name, &1})
    events_columns = Map.new(by_name["events"].columns, &{&1.name, &1})

    assert by_name["events"].partitioned
    assert by_name["events_p2026"].partition_of == "public.events"

    # GENERATED ALWAYS ... STORED columns have their own pg_attrdef row
    # (holding the generation expression) — a plain `ad.oid IS NOT NULL`
    # check would fabricate a `default` for them. `generated: :stored` and
    # `default: nil` must hold together, distinct from a real (volatile)
    # default like inserted_at's.
    assert events_columns["total"].generated == :stored
    assert events_columns["total"].default == nil
    assert events_columns["seq"].identity
    assert events_columns["inserted_at"].default.volatile

    assert Enum.any?(by_name["events_p2026"].indexes, & &1.partial)

    assert Enum.any?(by_name["events_p2026"].indexes, fn i ->
             Enum.any?(i.keys, &(&1.kind == :expression))
           end)

    assert Enum.any?(by_name["events_p2026"].indexes, &(&1.valid == false))
    assert Enum.any?(by_name["orgs"].constraints, &(&1.is_not_null_check_on == "name"))
    assert Enum.any?(by_name["events_p2026"].constraints, &(&1.type == :foreign_key))
    assert by_name["orgs"].n_live_tup == 100
  end

  @tag :tmp_dir
  test "the emit-sql script and from-file rebuild the same snapshot", %{tmp_dir: tmp_dir} do
    script = Path.join(tmp_dir, "cerbero_export.sql")
    output = Path.join(tmp_dir, "cerbero_export.out")
    File.write!(script, Exporter.emit_sql())

    run_psql_script(script, output)

    assert {:ok, from_file} = Exporter.from_file(output)
    assert {:ok, live} = Exporter.export(@url)

    # Structural equality, not point-in-time equality: applied_migrations
    # is read by both this psql script AND `export/2` itself, and that
    # read is a scan the migrations table's own pg_stat_user_tables row
    # will show — so running the exporter twice against the same live
    # target (as this test does, once via psql and once directly)
    # deterministically moves seq_scan/idx_scan/n_tup_* by exactly the
    # scans the exporter's own prior run performed. That drift is real
    # live telemetry, not a parsing discrepancy, so it's normalized out
    # here the same way collected_at/checksum are — everything else
    # (schema shape, defaults, indexes, constraints, row estimates) must
    # still match exactly.
    assert normalize(from_file) == normalize(live)
  end

  test "session is read-only" do
    # The exporter sets default_transaction_read_only; verify our queries module
    # holds no writes by grepping it — the belt to the runtime suspenders.
    source = File.read!("lib/cerbero/snapshot/exporter/queries.ex")
    refute source =~ ~r/\b(INSERT|UPDATE|DELETE|ALTER|DROP|CREATE|TRUNCATE|GRANT)\b/
  end

  test "precision: :order_of_magnitude exports only power-of-ten counts and bytes" do
    assert {:ok, raw} = Exporter.export(@url, precision: :order_of_magnitude)
    assert raw["precision"] == "order_of_magnitude"

    power_of_ten? = fn
      nil -> true
      n when n <= 0 -> true
      n when is_integer(n) -> n == Integer.pow(10, floor(:math.log10(n)))
      f when is_float(f) -> f == :math.pow(10, floor(:math.log10(f)))
    end

    for t <- raw["tables"] do
      for field <- ~w(reltuples relpages n_live_tup seq_scan idx_scan
                      n_tup_ins n_tup_upd n_tup_del heap_bytes total_bytes) do
        assert power_of_ten?.(t[field]),
               "#{t["name"]}.#{field} = #{inspect(t[field])} is not a power-of-ten bucket"
      end

      for idx <- t["indexes"] do
        assert power_of_ten?.(idx["bytes"])
      end
    end

    # the orgs seed has 100 rows exactly; bucketed export must not reveal more
    orgs = Enum.find(raw["tables"], &(&1["name"] == "orgs"))
    assert orgs["n_live_tup"] in [100, nil]

    # and it still strict-decodes as a current-format order-of-magnitude snapshot
    current = Snapshot.format_version()

    assert {:ok, %Snapshot{precision: :order_of_magnitude, format_version: ^current}} =
             raw |> Snapshot.stamp() |> Snapshot.decode()
  end

  @activity_counters ~w(seq_scan idx_scan n_tup_ins n_tup_upd n_tup_del)

  defp normalize(raw) do
    raw
    |> Map.delete("collected_at")
    |> Map.delete("checksum")
    |> Map.update!("tables", fn tables ->
      Enum.map(tables, &Map.drop(&1, @activity_counters))
    end)
  end

  # Run the emitted psql script and capture its tuples-only output. Prefers
  # a local `psql` (matches how a DBA would actually run this); falls back
  # to `docker compose exec` against the pg16 service when the host has
  # none, since psql is not guaranteed to be installed everywhere CI runs.
  defp run_psql_script(script, output) do
    if System.find_executable("psql") do
      {_, 0} =
        System.cmd("psql", [@url, "--no-psqlrc", "--tuples-only", "-f", script],
          into: File.stream!(output),
          stderr_to_stdout: false
        )
    else
      run_psql_script_via_docker(script, output)
    end
  end

  defp run_psql_script_via_docker(script, output) do
    container_script = "/tmp/cerbero_export.sql"

    {_, 0} =
      System.cmd(
        "docker",
        ["compose", "-f", "docker-compose.test.yml", "cp", script, "pg16:#{container_script}"]
      )

    {_, 0} =
      System.cmd(
        "docker",
        [
          "compose",
          "-f",
          "docker-compose.test.yml",
          "exec",
          "-T",
          "pg16",
          "psql",
          @container_url,
          "--no-psqlrc",
          "--tuples-only",
          "-f",
          container_script
        ],
        into: File.stream!(output)
      )
  end
end
