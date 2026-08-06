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

  test "CRDB: type change on an indexed column is rejected by the engine — error before deploy" do
    crdb = %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}

    assert [%Finding{severity: :error, message: msg}] =
             judge_rule(
               [events_with("integer")],
               "alter table(:events) do\n modify :id, :bigint\n end",
               snapshot: crdb
             )

    assert msg =~ "CockroachDB rejects"
  end
end
