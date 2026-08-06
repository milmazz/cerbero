defmodule Cerbero.Check.ConcurrentIndexRequiresAttributesTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.ConcurrentIndexRequiresAttributes

  test "concurrently: true without both attributes is an error (deploy-time failure + invalid index)" do
    assert [
             %Finding{
               check: :concurrent_index_requires_attributes,
               severity: :error,
               message: msg
             }
           ] =
             judge(
               [ConcurrentIndexRequiresAttributes],
               [table("events")],
               "create index(:events, [:org_id], concurrently: true)"
             )

    assert msg =~ "@disable_ddl_transaction"
    assert msg =~ "@disable_migration_lock"
  end

  test "with both attributes set: silent" do
    assert [] =
             judge(
               [ConcurrentIndexRequiresAttributes],
               [table("events")],
               "create index(:events, [:org_id], concurrently: true)",
               attrs: " @disable_ddl_transaction true\n @disable_migration_lock true"
             )
  end
end
