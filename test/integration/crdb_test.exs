defmodule Cerbero.Integration.CRDBTest do
  @moduledoc """
  Layer 4's CRDB differential: the exporter's strict decode must survive a
  real CockroachDB catalog (not just PG's), and `Cerbero.DDL.CRDB`'s
  limitation table must hold against the actual engine, not just its own
  say-so.

  It didn't, on first run. The brief's original second test asserted that
  CockroachDB rejects `ALTER COLUMN TYPE` on an indexed column — the exact
  claim `Cerbero.DDL.CRDB.judge(:alter_column_type_indexed, _)` encoded.
  Against a live CockroachDB v25.1.10 node it does not: the statement
  below (and the PK/CHECK/FK-constrained variants tried during
  investigation) all succeed via CRDB's validate/backfill schema-change
  job as long as the target type is data-compatible. The one case that
  does still reproducibly fail is different — a *separate* generated/
  computed column elsewhere in the table depending on the altered column
  (SQLSTATE 2BP01) — and that's what "rejected" now tests. `judge/2` was
  corrected to `{:limited, _}` for this class (see its comment for the
  full evidence); this file both documents the correction (`"...no
  longer rejects..."` test, a regression guard: if a future CRDB version
  reinstates the old restriction, that test — not a stale assumption —
  is what will tell us) and exercises the surviving true rejection.

  Same skip-when-unreachable mechanism as
  `test/integration/lock_verification_test.exs` — see that module's
  moduledoc for why `skip:` and not a runtime guard.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias Cerbero.Catalog
  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.{Exporter, Staleness}

  @url "postgresql://root@localhost:26257/defaultdb?sslmode=disable"

  up? =
    case :gen_tcp.connect(~c"localhost", 26257, [active: false], 300) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end

  if not up? do
    @moduletag skip:
                 "CockroachDB (localhost:26257) unreachable in this environment " <>
                   "— see task-19-report.md"
  end

  setup_all do
    {:ok, conn} = connect(@url)

    Postgrex.query!(
      conn,
      "CREATE TABLE IF NOT EXISTS orgs (id INT8 PRIMARY KEY, name STRING NOT NULL)",
      []
    )

    Postgrex.query!(conn, "CREATE INDEX IF NOT EXISTS orgs_name_idx ON orgs (name)", [])
    %{conn: conn}
  end

  test "engine detection + snapshot validates through the same strict decode" do
    assert {:ok, raw} = Exporter.export(@url)
    assert raw["engine"]["name"] == "cockroachdb"
    assert {:ok, %Snapshot{engine: %{name: :cockroachdb}}} = Snapshot.decode(Snapshot.stamp(raw))
  end

  test "regression guard: CRDB no longer rejects ALTER COLUMN TYPE on an indexed column", %{
    conn: conn
  } do
    assert {:ok, _} =
             Postgrex.query(conn, "ALTER TABLE orgs ALTER COLUMN name TYPE VARCHAR(10)", [])
  end

  test "row scale: n_live_tup is wired from crdb_internal.table_row_statistics, never fabricated to 0",
       %{conn: conn} do
    # DROP + CREATE fresh every run — not `CREATE TABLE IF NOT EXISTS` —
    # so this test cannot be fooled by a previous run's already-warmed
    # statistics into only ever exercising the "stats are ready" branch.
    # This is the actual bug a prior version of this test missed: CRDB's
    # `estimated_row_count` reads a literal `0` (not SQL NULL, confirmed
    # empirically) for a table whose statistics haven't propagated yet,
    # and that persisted for several seconds even after `CREATE
    # STATISTICS` completed — a bounded retry loop doesn't reliably outrun
    # it either. `Cerbero.Snapshot.Exporter.crdb_row_counts/2` now treats
    # a `0` read the same as "no signal" (mapped to nil, not forwarded),
    # so both outcomes below — stats hadn't propagated by export time, or
    # they had — are correct; only a fabricated `{:rows, 0, _}` is not.
    Postgrex.query!(conn, "DROP TABLE IF EXISTS rowcount_check", [])
    Postgrex.query!(conn, "CREATE TABLE rowcount_check (id INT8 PRIMARY KEY, v STRING)", [])

    Postgrex.query!(
      conn,
      "INSERT INTO rowcount_check (id, v) SELECT g, 'x' FROM generate_series(1, 3000) g",
      []
    )

    Postgrex.query!(
      conn,
      "CREATE STATISTICS cerbero_rowcount_check_stats FROM rowcount_check",
      []
    )

    assert {:ok, raw} = Exporter.export(@url)
    assert {:ok, snapshot} = Snapshot.decode(Snapshot.stamp(raw))

    staleness = %Staleness{age_days: 1, scale_mode: :exact, threshold_multiplier: 1.0}
    catalog = Catalog.from_snapshot(snapshot, staleness)

    case Catalog.scale(catalog, "rowcount_check") do
      {:rows, rows, _} ->
        assert rows > 0

      :unknown ->
        :ok

      other ->
        flunk(
          "expected {:rows, >0, _} or :unknown, never a fabricated zero; got #{inspect(other)}"
        )
    end

    refute match?({:rows, 0, _}, Catalog.scale(catalog, "rowcount_check"))
  end

  test "stats timestamps: statistics creation times land in last_analyze/last_autoanalyze",
       %{conn: conn} do
    Postgrex.query!(conn, "DROP TABLE IF EXISTS statsage_check", [])
    Postgrex.query!(conn, "CREATE TABLE statsage_check (id INT8 PRIMARY KEY, v STRING)", [])

    Postgrex.query!(
      conn,
      "INSERT INTO statsage_check (id, v) SELECT g, 'x' FROM generate_series(1, 100) g",
      []
    )

    # Unlike estimated_row_count (which lags, see the test above), the
    # statistics row itself is visible in system.table_statistics as soon
    # as the statement commits — confirmed empirically on v25.1.
    Postgrex.query!(
      conn,
      "CREATE STATISTICS cerbero_statsage_stats FROM statsage_check",
      []
    )

    assert {:ok, raw} = Exporter.export(@url)
    assert {:ok, snapshot} = Snapshot.decode(Snapshot.stamp(raw))
    t = Enum.find(snapshot.tables, &(&1.name == "statsage_check"))

    # Manually named statistics land in last_analyze; CRDB's automatic
    # collection (statistics named __auto__) lands in last_autoanalyze
    # and may or may not have fired for a table this young.
    assert %DateTime{} = t.last_analyze
  end

  test "the limitation table's surviving fact: a column a generated column depends on can't change type",
       %{conn: conn} do
    Postgrex.query!(
      conn,
      "CREATE TABLE IF NOT EXISTS orgs_gen (id INT8 PRIMARY KEY, x STRING, y STRING AS (x || '!') STORED)",
      []
    )

    assert {:error, %Postgrex.Error{}} =
             Postgrex.query(conn, "ALTER TABLE orgs_gen ALTER COLUMN x TYPE VARCHAR(20)", [])
  end

  # Postgrex.start_link/1 has no :url option — parse it the same way the
  # exporter and the lock-verification suite do.
  defp connect(url) do
    connect_opts =
      url
      |> Ecto.Repo.Supervisor.parse_url()
      # ecto's query-string parser turns `sslmode=disable` into a bare
      # `{:sslmode, "disable"}` pair it doesn't otherwise interpret (only
      # `ssl=true|false` is special-cased); Postgrex has no use for either
      # key, so both are dropped rather than passed through unrecognized.
      |> Keyword.delete(:scheme)
      |> Keyword.delete(:sslmode)
      |> Keyword.put(:pool_size, 1)

    Postgrex.start_link(connect_opts)
  end
end
