defmodule Cerbero.Check.DMLTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.DMLInMigration

  test "unbatched UPDATE at scale: warning with the row count" do
    assert [%Finding{check: :dml_in_migration, severity: :warning, message: msg}] =
             judge(
               [DMLInMigration],
               [big_events_table()],
               ~s|execute "UPDATE events SET org_id = 1"|
             )

    assert msg =~ "412M"
    assert msg =~ "single transaction"
  end

  test "small table: silent" do
    assert [] = judge([DMLInMigration], [table("prefs")], ~s|execute "UPDATE prefs SET x = 1"|)
  end

  test "unknown table: warning (unknown scale is unbounded)" do
    assert [%Finding{severity: :warning}] =
             judge([DMLInMigration], [], ~s|execute "UPDATE ghost SET x = 1"|)
  end
end
