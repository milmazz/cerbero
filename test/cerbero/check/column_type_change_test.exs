defmodule Cerbero.Check.ColumnTypeChangeTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.ColumnTypeChange

  defp judge_rule(tables, body, opts \\ []), do: judge([ColumnTypeChange], tables, body, opts)

  defp events_with(type, extra \\ %{}) do
    table(
      "events",
      Map.merge(
        %{
          "n_live_tup" => 412_000_000,
          "reltuples" => 412_000_000.0,
          "heap_bytes" => 219_902_325_555,
          "last_autoanalyze" => "2026-07-01T00:00:00Z",
          "columns" => [column("id", %{"type" => type, "not_null" => true})],
          "indexes" => [index("events_pkey", ["id"], %{"primary" => true, "unique" => true})]
        },
        extra
      )
    )
  end

  test "int -> bigint on 412M rows: AEL + rewrite + index rebuilds named, error" do
    assert [%Finding{check: :column_type_change, severity: :error, message: msg}] =
             judge_rule(
               [events_with("integer")],
               "alter table(:events) do\n modify :id, :bigint\n end"
             )

    assert msg =~ "rewrite"
    assert msg =~ "events_pkey"
  end

  test "varchar(50) -> varchar(255) is binary-coercible: silent at metadata cost, but never for AEL on hot tables" do
    t =
      events_with("character varying(50)", %{
        "n_live_tup" => 1000,
        "reltuples" => 1000.0,
        "heap_bytes" => 8192,
        "idx_scan" => 0,
        "seq_scan" => 0,
        "n_tup_ins" => 0,
        "n_tup_upd" => 0,
        "n_tup_del" => 0
      })

    assert [%Finding{severity: :info, message: msg}] =
             judge_rule([t], "alter table(:events) do\n modify :id, :string, size: 255\n end")

    assert msg =~ "lock_timeout"
  end

  test "same type: no finding" do
    t = events_with("bigint")
    assert [] = judge_rule([t], "alter table(:events) do\n modify :id, :bigint\n end")
  end

  test "CRDB: type change on an indexed column is restricted (not rejected) — warning before deploy" do
    # Was asserted as `:error`/"CockroachDB rejects..." until the layer 4
    # empirical differential (test/integration/crdb_test.exs) verified on
    # a live v25.1 node that ALTER COLUMN TYPE succeeds on an indexed (PK)
    # column when the cast is data-compatible (int -> bigint here) —
    # see the comment on `Cerbero.DDL.CRDB.judge(:alter_column_type_indexed, _)`.
    crdb = %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}

    assert [%Finding{severity: :warning, message: msg}] =
             judge_rule(
               [events_with("integer")],
               "alter table(:events) do\n modify :id, :bigint\n end",
               snapshot: crdb
             )

    assert msg =~ "restricted"
  end

  test "born-this-deploy silencing: create table and modify column type in same migration" do
    assert [] =
             judge_rule(
               [
                 table("events", %{
                   "n_live_tup" => 0,
                   "reltuples" => 0.0,
                   "heap_bytes" => 0,
                   "columns" => []
                 })
               ],
               "create table(:events) do\n add :id, :integer\n end\n alter table(:events) do\n modify :id, :bigint\n end"
             )
  end

  test "decimal(10,2) -> decimal(10,2) no-op: same type, no finding" do
    t =
      events_with("numeric(10,2)", %{
        "columns" => [
          column("price", %{"type" => "numeric(10,2)"})
        ]
      })

    assert [] =
             judge_rule(
               [t],
               "alter table(:events) do\n modify :price, :decimal, precision: 10, scale: 2\n end"
             )
  end

  test "unmappable custom type: no finding (false-positive guard)" do
    t =
      events_with("integer", %{
        "columns" => [
          column("custom_col", %{"type" => "custom_type"})
        ]
      })

    assert [] =
             judge_rule(
               [t],
               "alter table(:events) do\n modify :custom_col, :some_custom_type\n end"
             )
  end

  test "CRDB: type change on a column with FK constraint is restricted (not rejected)" do
    # Same layer 4 correction as above — verified empirically that CRDB
    # v25.1 also allows this cast on an FK-constrained column.
    crdb = %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}

    t =
      table("events", %{
        "n_live_tup" => 1000,
        "reltuples" => 1000.0,
        "columns" => [
          column("org_id", %{"type" => "integer"})
        ],
        "constraints" => [
          %{
            "name" => "fk_events_orgs",
            "type" => "foreign_key",
            "columns" => ["org_id"],
            "references" => %{"table" => "orgs", "columns" => ["id"]},
            "validated" => true,
            "on_delete" => "no_action",
            "on_update" => "no_action",
            "is_not_null_check_on" => nil
          }
        ]
      })

    assert [%Finding{severity: :warning, message: msg}] =
             judge_rule(
               [t],
               "alter table(:events) do\n modify :org_id, :bigint\n end",
               snapshot: crdb
             )

    assert msg =~ "restricted"
  end

  test "CRDB: a separate stored generated column in the table names the 2BP01 rejection" do
    crdb = %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}

    t =
      table("events", %{
        "columns" => [
          column("id", %{"type" => "integer"}),
          column("id_text", %{"type" => "text", "generated" => "stored"})
        ]
      })

    assert [%Finding{severity: :warning, message: msg}] =
             judge_rule(
               [t],
               "alter table(:events) do\n modify :id, :bigint\n end",
               snapshot: crdb
             )

    assert msg =~ "2BP01"
    assert msg =~ "id_text"
  end

  test "CRDB: the modified column being generated itself does not trigger the 2BP01 message" do
    crdb = %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}

    t =
      table("events", %{
        "columns" => [column("id_text", %{"type" => "text", "generated" => "stored"})]
      })

    assert [%Finding{severity: :warning, message: msg}] =
             judge_rule(
               [t],
               "alter table(:events) do\n modify :id_text, :string, size: 64\n end",
               snapshot: crdb
             )

    refute msg =~ "2BP01"
    assert msg =~ "restricted"
  end
end
