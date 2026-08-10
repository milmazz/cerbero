defmodule Cerbero.Check.DisabledTransactionScopeTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.DisabledTransactionScope

  @attrs " @disable_ddl_transaction true\n @disable_migration_lock true"

  defp judge_rule(body, opts \\ []), do: judge([DisabledTransactionScope], [table("events")], body, opts)

  test "no @disable_ddl_transaction: silent regardless of body" do
    assert [] = judge_rule("create table(:widgets) do\n add :name, :string\n end")
  end

  test "@disable_ddl_transaction with only a concurrent index: silent" do
    assert [] = judge_rule("create index(:events, [:org_id], concurrently: true)", attrs: @attrs)
  end

  test "@disable_ddl_transaction with a concurrent index drop: silent" do
    assert [] = judge_rule("drop index(:events, [:org_id], concurrently: true)", attrs: @attrs)
  end

  test "raw CREATE INDEX CONCURRENTLY under @disable_ddl_transaction: silent" do
    assert [] =
             judge_rule(
               ~s|execute "CREATE INDEX CONCURRENTLY events_org_id_idx ON events (org_id)"|,
               attrs: @attrs
             )
  end

  test "concurrent index mixed with a create table flags only the create table" do
    assert [%Finding{check: :disabled_transaction_scope, severity: :warning, message: msg}] =
             judge_rule(
               "create index(:events, [:org_id], concurrently: true)\n" <>
                 "create table(:widgets) do\n add :name, :string\n end",
               attrs: @attrs
             )

    assert msg =~ "create table"
    assert msg =~ "@disable_ddl_transaction"
  end

  test "non-concurrent index under @disable_ddl_transaction is flagged" do
    assert [%Finding{check: :disabled_transaction_scope, severity: :warning, message: msg}] =
             judge_rule("create index(:events, [:org_id])", attrs: @attrs)

    assert msg =~ "non-concurrent index"
  end

  test "alter table under @disable_ddl_transaction is flagged" do
    assert [%Finding{severity: :warning, message: msg}] =
             judge_rule("alter table(:events) do\n add :flag, :boolean\n end", attrs: @attrs)

    assert msg =~ "alter table"
  end

  test "a rename under @disable_ddl_transaction is flagged" do
    assert [%Finding{message: msg}] = judge_rule("rename table(:events), to: table(:events_old)", attrs: @attrs)
    assert msg =~ "rename"
  end

  test "a transactional raw SQL statement under @disable_ddl_transaction is flagged" do
    assert [%Finding{message: msg}] =
             judge_rule(~s|execute "ALTER TABLE events ADD COLUMN flag integer"|, attrs: @attrs)

    assert msg =~ "add_column"
  end

  test "raw ALTER TYPE ADD VALUE / ANALYZE (classifier :unknown) is left to MetaFindings, not double-flagged" do
    assert [] = judge_rule(~s|execute "ALTER TYPE mood ADD VALUE 'excited'"|, attrs: @attrs)
    assert [] = judge_rule(~s|execute "ANALYZE events"|, attrs: @attrs)
  end
end
