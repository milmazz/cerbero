defmodule Cerbero.Check.NotNullTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.NotNullOnPopulatedTable

  defp judge_rule(tables, body, opts \\ []),
    do: judge([NotNullOnPopulatedTable], tables, body, opts)

  test "SET NOT NULL on a populated table without a proving CHECK: severity by rows, two-step spelled out" do
    assert [%Finding{check: :not_null_on_populated_table, severity: :error, message: msg}] =
             judge_rule(
               [big_events_table()],
               "modify :org_id, :bigint, null: false" |> in_alter("events")
             )

    assert msg =~ "full-table scan under ACCESS EXCLUSIVE"
    assert msg =~ "CHECK (org_id IS NOT NULL) NOT VALID"
    assert msg =~ "VALIDATE CONSTRAINT"
  end

  test "silent when the column is already NOT NULL in the snapshot" do
    t =
      table("events", %{
        "columns" => [column("org_id", %{"not_null" => true})],
        "n_live_tup" => 5_000_000,
        "reltuples" => 5_000_000.0
      })

    assert [] = judge_rule([t], "modify :org_id, :bigint, null: false" |> in_alter("events"))
  end

  test "PG >= 12 with a validated IS NOT NULL check (snapshot): metadata-only info note" do
    t =
      table("events", %{
        "n_live_tup" => 5_000_000,
        "reltuples" => 5_000_000.0,
        "columns" => [column("org_id")],
        "constraints" => [
          %{
            "columns" => ["org_id"],
            "is_not_null_check_on" => "org_id",
            "name" => "org_id_nn",
            "on_delete" => nil,
            "on_update" => nil,
            "references" => nil,
            "type" => "check",
            "validated" => true
          }
        ]
      })

    assert [%Finding{severity: :info, message: msg}] =
             judge_rule([t], "modify :org_id, :bigint, null: false" |> in_alter("events"))

    assert msg =~ "scan is skipped"
  end

  test "recognizes its own recommended two-step in raw SQL across pending migrations (overlay)" do
    # Overlay case is covered by catalog_overlay_test; here: the raw-SQL SET NOT NULL form fires too.
    t =
      table("events", %{
        "n_live_tup" => 5_000_000,
        "reltuples" => 5_000_000.0,
        "columns" => [column("org_id")]
      })

    assert [%Finding{severity: :error}] =
             judge_rule([t], ~s|execute "ALTER TABLE events ALTER COLUMN org_id SET NOT NULL"|)
  end

  test "CRDB: online validation scan cost note, never 'ACCESS EXCLUSIVE'" do
    crdb = %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}

    assert [%Finding{severity: :warning, message: msg}] =
             judge_rule(
               [big_events_table()],
               "modify :org_id, :bigint, null: false" |> in_alter("events"),
               snapshot: crdb
             )

    refute msg =~ "ACCESS EXCLUSIVE"
    assert msg =~ "online validation scan"
  end

  test "CRDB: small table is silent" do
    crdb = %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}
    small = table("events", %{"columns" => [column("org_id")]})

    assert [] =
             judge_rule(
               [small],
               "modify :org_id, :bigint, null: false" |> in_alter("events"),
               snapshot: crdb
             )
  end

  test "silent when table is born in this migration, unbackfilled" do
    # Create table and modify column in same migration: should be silent (born_this_deploy rule)
    assert [] =
             judge_rule(
               [],
               """
               create table(:new_events) do
                 add :status, :string
               end
               alter table(:new_events) do
                 modify :status, :string, null: false
               end
               """
             )
  end

  def in_alter(body, table), do: "alter table(:#{table}) do\n #{body}\n end"
end
