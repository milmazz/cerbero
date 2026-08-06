defmodule Cerbero.Integration.LockVerificationTest do
  @moduledoc """
  Layer 4's empirical anchor: for every `Cerbero.DDL.Locks` PG entry that
  has an in-transaction-executable representative statement, run that
  statement inside a transaction, read `pg_locks`, assert the mapped
  mode, roll back. Any mismatch here is a bug in `Locks` (data), not in
  this test — see the module doc there.

  Excluded from the per-class loop, each with a reason:

    * `create_index_concurrently`, `drop_index_concurrently`,
      `reindex_concurrently`, `detach_partition_concurrently` — CONCURRENTLY
      DDL cannot run inside an explicit transaction block at all (PG error
      25001, `active_sql_transaction`). That refusal is itself rule 10's
      premise and gets one direct behavioral test below (CREATE INDEX
      CONCURRENTLY stands in for the whole family — same PG restriction,
      same error code, no per-statement variation to observe).
    * `create_table` — maps to lock `:none`, which is not a `pg_locks`
      mode at all; it encodes "nothing could have been contending for a
      relation that doesn't exist yet," not an observed lock. There is no
      `@lock_names` entry for it by design (see `Locks` moduledoc).

  Each PG leg (`describe "PG 13"` / `describe "PG 16"`) only actually runs
  its tests if that port answers a TCP connect at compile time (a fast,
  short-timeout probe — see the `reachable?` check below). An unreachable
  leg gets
  `@describetag skip: "..."` — ExUnit's own skip mechanism — rather than a
  runtime `if` guard inside each test body. That distinction matters: a
  `skip:` tag makes `mix test` report the tests as **skipped**, a visible,
  counted outcome distinct from both pass and fail, and it does so *before*
  `setup` ever runs, so an unreachable leg never even attempts to connect.
  A runtime guard that just returned `:ok` early from inside the test body
  would instead read as a pass — indistinguishable from having verified
  anything. Whichever legs are unreachable in a given environment are
  listed in the layer 4 report, not silently dropped.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  alias Cerbero.DDL.Locks

  @urls %{
    130_000 => "postgres://postgres:cerbero@localhost:54313/cerbero_test",
    160_000 => "postgres://postgres:cerbero@localhost:54316/cerbero_test"
  }

  # Fast (300ms) TCP-connect probe, evaluated once per URL while this file
  # compiles — i.e. once per `mix test` invocation, which is exactly when
  # "is the container up right now" needs answering. Not a DNS/auth/pgwire
  # check, just "is anything listening" — enough to distinguish "container
  # absent" from "container present but broken," and the latter should
  # still fail loudly rather than be swallowed as a skip.
  #
  # This has to be a local anonymous function, not a `defp`: the `for`
  # loop below calls it while the module is still being compiled (it's
  # top-level module-body code, executed as the file loads), and a `defp`
  # isn't a callable function until the enclosing module finishes
  # compiling — calling one from module-body code raises `undefined
  # function` at compile time.
  reachable? = fn host, port ->
    case :gen_tcp.connect(String.to_charlist(host), port, [active: false], 300) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  # class -> {setup SQL (nil | string | [string], run pre-transaction and
  # committed), statement (run inside the transaction under test), relation
  # whose pg_locks row is asserted on}
  @statements %{
    create_index: {nil, "CREATE INDEX lv_idx ON lv_t (x)", "lv_t"},
    drop_index:
      {"CREATE INDEX IF NOT EXISTS lv_drop_idx ON lv_t (x)", "DROP INDEX lv_drop_idx", "lv_t"},
    add_column_constant_default: {nil, "ALTER TABLE lv_t ADD COLUMN c1 int DEFAULT 0", "lv_t"},
    add_column_volatile_default:
      {nil, "ALTER TABLE lv_t ADD COLUMN c2 float DEFAULT random()", "lv_t"},
    add_column_generated_stored:
      {nil, "ALTER TABLE lv_t ADD COLUMN c3 int GENERATED ALWAYS AS (x + 1) STORED", "lv_t"},
    add_primary_key: {nil, "ALTER TABLE lv_nopk ADD PRIMARY KEY (id)", "lv_nopk"},
    add_unique: {nil, "ALTER TABLE lv_t ADD CONSTRAINT lv_u UNIQUE (x)", "lv_t"},
    set_not_null: {nil, "ALTER TABLE lv_t ALTER COLUMN x SET NOT NULL", "lv_t"},
    add_check: {nil, "ALTER TABLE lv_t ADD CONSTRAINT lv_c CHECK (x >= 0)", "lv_t"},
    add_check_not_valid:
      {nil, "ALTER TABLE lv_t ADD CONSTRAINT lv_cnv CHECK (x >= 0) NOT VALID", "lv_t"},
    validate_check:
      {"ALTER TABLE lv_t ADD CONSTRAINT lv_cv CHECK (x >= 0) NOT VALID",
       "ALTER TABLE lv_t VALIDATE CONSTRAINT lv_cv", "lv_t"},
    add_foreign_key:
      {nil, "ALTER TABLE lv_t ADD CONSTRAINT lv_fk FOREIGN KEY (ref_id) REFERENCES lv_ref (id)",
       "lv_t"},
    add_foreign_key_not_valid:
      {nil,
       "ALTER TABLE lv_t ADD CONSTRAINT lv_fknv FOREIGN KEY (ref_id) REFERENCES lv_ref (id) NOT VALID",
       "lv_t"},
    validate_foreign_key:
      {"ALTER TABLE lv_t ADD CONSTRAINT lv_fkv FOREIGN KEY (ref_id) REFERENCES lv_ref (id) NOT VALID",
       "ALTER TABLE lv_t VALIDATE CONSTRAINT lv_fkv", "lv_t"},
    alter_column_type: {nil, "ALTER TABLE lv_t ALTER COLUMN x TYPE bigint", "lv_t"},
    alter_column_type_binary_coercible:
      {nil, "ALTER TABLE lv_t ALTER COLUMN v TYPE varchar(20)", "lv_t"},
    attach_partition:
      {nil,
       "ALTER TABLE lv_part ATTACH PARTITION lv_part_child FOR VALUES FROM ('2020-01-01') TO ('2021-01-01')",
       "lv_part"},
    detach_partition:
      {"ALTER TABLE lv_part ATTACH PARTITION lv_part_child FOR VALUES FROM ('2020-01-01') TO ('2021-01-01')",
       "ALTER TABLE lv_part DETACH PARTITION lv_part_child", "lv_part"},
    set_logged: {nil, "ALTER TABLE lv_setlogged SET UNLOGGED", "lv_setlogged"},
    truncate: {nil, "TRUNCATE lv_t", "lv_t"},
    reindex: {nil, "REINDEX TABLE lv_t", "lv_t"},
    drop_column: {nil, "ALTER TABLE lv_t DROP COLUMN droppable", "lv_t"},
    drop_table: {nil, "DROP TABLE lv_drop_target", "lv_drop_target"},
    rename: {nil, "ALTER TABLE lv_t RENAME COLUMN x TO x2", "lv_t"},
    set_default: {nil, "ALTER TABLE lv_t ALTER COLUMN x SET DEFAULT 1", "lv_t"},
    dml_update: {nil, "UPDATE lv_t SET x = x", "lv_t"},
    dml_delete: {nil, "DELETE FROM lv_t WHERE false", "lv_t"},
    dml_insert_select: {nil, "INSERT INTO lv_t (x) SELECT x FROM lv_t WHERE false", "lv_t"}
  }

  @lock_names %{
    access_exclusive: "AccessExclusiveLock",
    share: "ShareLock",
    share_row_exclusive: "ShareRowExclusiveLock",
    share_update_exclusive: "ShareUpdateExclusiveLock",
    row_exclusive: "RowExclusiveLock"
  }

  for {version_num, url} <- @urls do
    %{host: host, port: port} = URI.parse(url)
    pg_version = div(version_num, 10_000)
    up? = reachable?.(host, port)

    describe "PG #{pg_version}" do
      if not up? do
        @describetag skip:
                       "PG #{pg_version} (#{host}:#{port}) unreachable in this environment " <>
                         "— see task-19-report.md"
      end

      setup do
        {:ok, conn} = connect(unquote(url))

        Postgrex.query!(
          conn,
          """
          DROP TABLE IF EXISTS
            lv_t, lv_nopk, lv_ref, lv_drop_target, lv_setlogged, lv_part_child, lv_part
          CASCADE
          """,
          []
        )

        Postgrex.query!(conn, "CREATE TABLE lv_ref (id bigint PRIMARY KEY)", [])

        Postgrex.query!(
          conn,
          "CREATE TABLE lv_t (id bigserial PRIMARY KEY, x int, ref_id bigint, droppable int, v varchar(10))",
          []
        )

        Postgrex.query!(conn, "CREATE TABLE lv_nopk (id bigint NOT NULL)", [])
        Postgrex.query!(conn, "CREATE TABLE lv_drop_target (id int)", [])
        # Plain (non-serial) table, dedicated to the set_logged case: PG
        # only supports unlogged sequences since 15 (verified: works fine
        # against lv_t's bigserial on PG 16; PG 13 is the version this
        # would actually bite on). Rather than branch the test on server
        # version, sidestep the whole question by construction — this
        # fixture has nothing owned-sequence to conflict with, on any
        # supported PG.
        Postgrex.query!(conn, "CREATE TABLE lv_setlogged (id int, x int)", [])

        Postgrex.query!(
          conn,
          "CREATE TABLE lv_part (id bigint, d date) PARTITION BY RANGE (d)",
          []
        )

        Postgrex.query!(conn, "CREATE TABLE lv_part_child (id bigint, d date)", [])

        %{conn: conn}
      end

      for {class, {setup_sql, stmt, relation}} <- @statements do
        test "#{class}: #{stmt}", %{conn: conn} do
          for sql <- List.wrap(unquote(setup_sql)), do: Postgrex.query!(conn, sql, [])

          {expected_lock, _cost} = Locks.entry(unquote(class), :postgres, unquote(version_num))

          # Resolve the relation's oid BEFORE the transaction: for
          # `drop_table` the name no longer resolves via ::regclass once
          # the DROP has run (even mid-transaction, pre-rollback), since
          # the catalog row is gone from that command's snapshot onward.
          # Locking up-front by oid instead of by ::regclass-at-query-time
          # is correct for every class, not just that one.
          %{rows: [[relation_oid]]} =
            Postgrex.query!(conn, "SELECT to_regclass($1)::oid", [unquote(relation)])

          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, unquote(stmt), [])

            %{rows: rows} =
              Postgrex.query!(
                tx,
                "SELECT mode FROM pg_locks WHERE pid = pg_backend_pid() AND relation = $1",
                [relation_oid]
              )

            modes = List.flatten(rows)

            assert @lock_names[expected_lock] in modes,
                   "#{unquote(class)}: expected #{expected_lock} on #{unquote(relation)}, got #{inspect(modes)}"

            Postgrex.rollback(tx, :done)
          end)
        end
      end

      test "CREATE INDEX CONCURRENTLY refuses to run in a transaction (rule 10's premise; " <>
             "stands in for the whole CONCURRENTLY family — same PG restriction, same error code)",
           %{conn: conn} do
        Postgrex.query!(conn, "CREATE TABLE IF NOT EXISTS lv_cic (x int)", [])

        Postgrex.transaction(conn, fn tx ->
          assert {:error, %Postgrex.Error{postgres: %{code: :active_sql_transaction}}} =
                   Postgrex.query(tx, "CREATE INDEX CONCURRENTLY lv_cic_idx ON lv_cic (x)", [])

          Postgrex.rollback(tx, :done)
        end)
      end
    end
  end

  # Postgrex.start_link/1 has no :url option — parse it the same way the
  # exporter and its integration test do.
  defp connect(url) do
    connect_opts =
      url
      |> Ecto.Repo.Supervisor.parse_url()
      |> Keyword.delete(:scheme)
      |> Keyword.put(:pool_size, 1)

    Postgrex.start_link(connect_opts)
  end
end
