defmodule Cerbero.Check.UnsafeIndexCreationTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.UnsafeIndexCreation

  defp judge_rule(tables, body, opts \\ []), do: judge([UnsafeIndexCreation], tables, body, opts)

  test "the definition-of-done sentence: non-concurrent index on 412M rows is an error" do
    assert [%Finding{check: :unsafe_index_creation, severity: :error, message: msg, line: 5}] =
             judge_rule([big_events_table()], "create index(:events, [:org_id])")

    assert msg =~
             "SHARE lock blocks writes on public.events (~412M rows, stats 2026-07-01) for a full-table scan"

    assert msg =~ "concurrently: true"
  end

  test "silent on small cold tables by default; strict mode restores always-fire" do
    small = table("prefs")
    assert [] = judge_rule([small], "create index(:prefs, [:user_id])")

    assert [%Finding{severity: :warning}] =
             judge_rule([small], "create index(:prefs, [:user_id])",
               config: [strict_concurrent_index: true]
             )
  end

  test "silent on born_this_deploy tables" do
    assert [] =
             judge_rule([], """
             create table(:events_v2) do
               add :org_id, :bigint
             end
             create index(:events_v2, [:org_id])
             """)
  end

  test "partitioned parent gets the per-partition recipe, judged at summed scale" do
    tables = [
      table("events", %{"partitioned" => true, "n_live_tup" => 0, "reltuples" => 0.0}),
      table("events_p0", %{
        "partition_of" => "public.events",
        "n_live_tup" => 2_000_000,
        "reltuples" => 2_000_000.0
      })
    ]

    assert [%Finding{severity: :error, message: msg}] =
             judge_rule(tables, "create index(:events, [:org_id])")

    assert msg =~ "per-partition"
    assert msg =~ "ON ONLY"
    refute msg =~ "concurrently: true with"
  end

  test "concurrent index on PG emits nothing here (rule 10's territory)" do
    assert [] =
             judge_rule(
               [big_events_table()],
               "create index(:events, [:org_id], concurrently: true)",
               attrs: " @disable_ddl_transaction true\n @disable_migration_lock true"
             )
  end

  test "non-concurrent DROP INDEX at scale recommends the CONCURRENTLY form" do
    assert [%Finding{message: msg}] =
             judge_rule([big_events_table()], "drop index(:events, [:org_id])")

    assert msg =~ "DROP INDEX CONCURRENTLY"
  end

  test "CRDB: lock warning suppressed, cost finding remains at scale" do
    crdb = %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}

    assert [%Finding{severity: :warning, message: msg}] =
             judge_rule([big_events_table()], "create index(:events, [:org_id])", snapshot: crdb)

    assert msg =~ "foreground cluster resources"
    refute msg =~ "SHARE lock"
  end
end
