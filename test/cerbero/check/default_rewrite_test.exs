defmodule Cerbero.Check.DefaultRewriteTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.ColumnDefaultRewrite

  defp judge_rule(tables, body, opts \\ []), do: judge([ColumnDefaultRewrite], tables, body, opts)

  defp alter_events(body), do: "alter table(:events) do\n #{body}\n end"

  test "constant default is metadata-only within the PG >= 13 floor: silent" do
    assert [] = judge_rule([big_events_table()], alter_events("add :flags, :integer, default: 0"))
  end

  test "volatile default rewrites at scale: error" do
    assert [%Finding{check: :column_default_rewrite, severity: :error, message: msg}] =
             judge_rule(
               [big_events_table()],
               alter_events(~s|add :token, :uuid, default: fragment("gen_random_uuid()")|)
             )

    assert msg =~ "rewrite"
  end

  test "GENERATED ... STORED rewrites on every version — the folklore trap" do
    assert [%Finding{severity: :error, message: msg}] =
             judge_rule(
               [big_events_table()],
               alter_events(~s|add :total, :bigint, generated: "ALWAYS AS (1) STORED"|)
             )

    assert msg =~ "GENERATED"
  end

  test "CRDB: online backfill cost note instead of lock warning" do
    crdb = %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}

    assert [%Finding{severity: :warning, message: msg}] =
             judge_rule(
               [big_events_table()],
               alter_events(~s|add :token, :uuid, default: fragment("gen_random_uuid()")|),
               snapshot: crdb
             )

    assert msg =~ "backfill"
    refute msg =~ "ACCESS EXCLUSIVE"
  end

  test "CRDB: small table with volatile default is silent" do
    crdb = %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}
    small = table("events", %{"n_live_tup" => 100, "reltuples" => 100.0})

    assert [] =
             judge_rule(
               [small],
               alter_events(~s|add :token, :uuid, default: fragment("gen_random_uuid()")|),
               snapshot: crdb
             )
  end

  test "silent when table is born in this migration, unbackfilled" do
    # Create table and add volatile-default column in same migration: should be silent (born_this_deploy rule)
    assert [] =
             judge_rule(
               [],
               """
               create table(:new_events) do
                 add :id, :bigint, primary_key: true
               end
               alter table(:new_events) do
                 add :token, :uuid, default: fragment("gen_random_uuid()")
               end
               """
             )
  end
end
