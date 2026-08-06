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
end
