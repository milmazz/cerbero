defmodule Cerbero.Check.RawDDLSafetyTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.RawDDLSafety

  defp judge_rule(tables, body, opts \\ []), do: judge([RawDDLSafety], tables, body, opts)

  test "raw ALTER COLUMN TYPE on 412M rows: error (previously silent — no rule owned it)" do
    assert [%Finding{check: :raw_ddl_safety, severity: :error, message: msg}] =
             judge_rule(
               [big_events_table()],
               ~s|execute "ALTER TABLE events ALTER COLUMN id TYPE bigint"|
             )

    assert msg =~ "ACCESS EXCLUSIVE"
    assert msg =~ "rewrite"
  end

  test "TRUNCATE on a known non-born table: error, regardless of scale" do
    assert [%Finding{check: :raw_ddl_safety, severity: :error, message: msg}] =
             judge_rule([table("prefs")], ~s|execute "TRUNCATE prefs"|)

    assert msg =~ "destructive"
    assert msg =~ "irreversible"
  end

  test "TRUNCATE on the 412M table: still error (destructive floor, not scale-gated)" do
    assert [%Finding{check: :raw_ddl_safety, severity: :error}] =
             judge_rule([big_events_table()], ~s|execute "TRUNCATE events"|)
  end

  test "raw DROP TABLE on a big table: a finding (AEL queues behind long-running queries)" do
    assert [%Finding{check: :raw_ddl_safety, severity: :warning, message: msg}] =
             judge_rule([big_events_table()], ~s|execute "DROP TABLE events"|)

    assert msg =~ "lock_timeout"
  end

  test "generic raw ADD CONSTRAINT ... CHECK (non IS-NOT-NULL) at scale: error" do
    assert [%Finding{check: :raw_ddl_safety, severity: :error, message: msg}] =
             judge_rule(
               [big_events_table()],
               ~s|execute "ALTER TABLE events ADD CONSTRAINT positive CHECK (org_id > 0)"|
             )

    assert msg =~ "full-table scan"
  end

  test "born table: create-then-truncate in the same pending set is silent" do
    assert [] =
             judge_rule([], """
             create table(:events_v2) do
               add :id, :bigint, primary_key: true
             end
             execute "TRUNCATE events_v2"
             """)
  end

  test "born table: create-then-raw-alter-type in the same pending set is silent" do
    assert [] =
             judge_rule([], """
             create table(:events_v2) do
               add :id, :bigint
             end
             execute "ALTER TABLE events_v2 ALTER COLUMN id TYPE bigint"
             """)
  end

  test "born table: create-then-raw-drop-table in the same pending set is silent" do
    assert [] =
             judge_rule([], """
             create table(:events_v2) do
               add :id, :bigint
             end
             execute "DROP TABLE events_v2"
             """)
  end

  describe "IMPORTANT 4: raw DROP INDEX / REINDEX target resolution" do
    test "raw DROP INDEX resolves against the catalog and is judged against the owning table" do
      t =
        table("events", %{
          "indexes" => [index("events_org_id_index", ["org_id"])]
        })

      assert [%Finding{check: :raw_ddl_safety, message: msg}] =
               judge_rule([t], ~s|execute "DROP INDEX events_org_id_index"|)

      assert msg =~ "public.events"
    end

    test "raw DROP INDEX on an index absent from the catalog: unresolvable, but never silent" do
      assert [%Finding{check: :raw_ddl_safety, severity: :info, message: msg}] =
               judge_rule([table("events")], ~s|execute "DROP INDEX ghost_idx"|)

      assert msg =~ "cannot resolve"
      assert msg =~ "lock_timeout"
    end

    test "raw REINDEX: the classifier captures no name, so it is always the unresolvable note" do
      assert [%Finding{check: :raw_ddl_safety, severity: :info, message: msg}] =
               judge_rule([table("events")], ~s|execute "REINDEX TABLE events"|)

      assert msg =~ "cannot resolve"
    end

    test "raw DROP INDEX resolved to a small cold table: still an info note (AEL is never silent)" do
      t = table("prefs", %{"indexes" => [index("prefs_user_id_index", ["user_id"])]})

      assert [%Finding{check: :raw_ddl_safety, severity: :info, message: msg}] =
               judge_rule([t], ~s|execute "DROP INDEX prefs_user_id_index"|)

      assert msg =~ "public.prefs"
    end
  end
end
