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

  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Exporter

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
