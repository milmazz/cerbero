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

  test "raw-SQL CREATE INDEX CONCURRENTLY without both attributes is the same error" do
    # Rule 1's own partitioned-parent remediation recommends raw
    # per-partition CIC — following that advice must not fail at deploy time.
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
               ~s|execute "CREATE INDEX CONCURRENTLY events_org_id_idx ON events (org_id)"|
             )

    assert msg =~ "@disable_ddl_transaction"
    assert msg =~ "@disable_migration_lock"
  end

  test "raw-SQL CREATE INDEX CONCURRENTLY with both attributes set: silent" do
    assert [] =
             judge(
               [ConcurrentIndexRequiresAttributes],
               [table("events")],
               ~s|execute "CREATE INDEX CONCURRENTLY events_org_id_idx ON events (org_id)"|,
               attrs: " @disable_ddl_transaction true\n @disable_migration_lock true"
             )
  end

  test "raw-SQL non-concurrent CREATE INDEX is not rule 10's concern" do
    assert [] =
             judge(
               [ConcurrentIndexRequiresAttributes],
               [table("events")],
               ~s|execute "CREATE INDEX events_org_id_idx ON events (org_id)"|
             )
  end
end
