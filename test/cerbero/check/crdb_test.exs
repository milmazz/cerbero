defmodule Cerbero.Check.CRDBTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.CRDBTransactionalDDL

  @crdb %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}

  defp judge_rule(tables, body, opts \\ []) do
    judge([CRDBTransactionalDDL], tables, body, Keyword.merge([snapshot: @crdb], opts))
  end

  test "multiple DDL in one transactional migration: warning" do
    assert [%Finding{check: :crdb_transactional_ddl, severity: :warning}] =
             judge_rule([table("events")], """
             create index(:events, [:org_id])
             alter table(:events) do
               add :flags, :integer
             end
             """)
  end

  test "ALTER COLUMN TYPE mixed with other DDL: error" do
    assert findings =
             judge_rule(
               [table("events", %{"columns" => [column("id", %{"type" => "integer"})]})],
               """
               alter table(:events) do
                 modify :id, :bigint
               end
               create index(:events, [:org_id])
               """
             )

    assert Enum.any?(findings, &(&1.severity == :error))
  end

  test "@disable_ddl_transaction silences the transactional warning" do
    assert [] =
             judge_rule(
               [table("events")],
               """
               create index(:events, [:org_id])
               alter table(:events) do
                 add :flags, :integer
               end
               """,
               attrs: " @disable_ddl_transaction true"
             )
  end

  test "on postgres this rule is silent" do
    assert [] =
             judge([CRDBTransactionalDDL], [table("events")], """
             create index(:events, [:org_id])
             alter table(:events) do
               add :flags, :integer
             end
             """)
  end
end
