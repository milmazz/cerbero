defmodule Cerbero.Check.FKTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.{FKMissingIndex, FKValidationScan}

  defp orgs,
    do:
      table("orgs", %{
        "n_live_tup" => 41_000_000,
        "reltuples" => 41_000_000.0,
        "last_autoanalyze" => "2026-07-01T00:00:00Z"
      })

  test "ADD FK without validate: false — both tables' scale, referenced-table lock named" do
    assert [%Finding{check: :fk_validation_scan, severity: :error, message: msg}] =
             judge([FKValidationScan], [big_events_table(), orgs()], """
             alter table(:events) do
               add :owner_org_id, references(:orgs)
             end
             """)

    assert msg =~ "writes to public.orgs (~41M rows"
    assert msg =~ "public.events (~412M rows"
    assert msg =~ "validate: false"
  end

  test "with validate: false: silent (metadata only)" do
    assert [] =
             judge([FKValidationScan], [big_events_table(), orgs()], """
             alter table(:events) do
               add :owner_org_id, references(:orgs, validate: false)
             end
             """)
  end

  test "NOT-VALID advice is version-gated for partitioned referencing tables below PG 18" do
    partitioned_events = table("events", %{"partitioned" => true})

    p0 =
      table("events_p0", %{
        "partition_of" => "public.events",
        "n_live_tup" => 2_000_000,
        "reltuples" => 2_000_000.0
      })

    assert [%Finding{message: msg}] =
             judge([FKValidationScan], [partitioned_events, p0, orgs()], """
             alter table(:events) do
               add :owner_org_id, references(:orgs)
             end
             """)

    refute msg =~ "validate: false"
    assert msg =~ "PG 18"
  end

  test "new FK with no covering index on the referencing column" do
    assert [%Finding{check: :fk_missing_index, severity: :warning, message: msg}] =
             judge([FKMissingIndex], [big_events_table(), orgs()], """
             alter table(:events) do
               add :owner_org_id, references(:orgs, validate: false)
             end
             """)

    assert msg =~ "owner_org_id"
  end

  test "an index created in the same migration counts as covering" do
    assert [] =
             judge(
               [FKMissingIndex],
               [big_events_table(), orgs()],
               """
               alter table(:events) do
                 add :owner_org_id, references(:orgs, validate: false)
               end
               create index(:events, [:owner_org_id], concurrently: true)
               """,
               attrs: " @disable_ddl_transaction true\n @disable_migration_lock true"
             )
  end

  test "raw SQL FK without referenced table (unparseable) does not crash and produces finding" do
    assert [%Finding{check: :fk_validation_scan, severity: :error}] =
             judge([FKValidationScan], [big_events_table(), orgs()], """
             execute \"ALTER TABLE events ADD CONSTRAINT c FOREIGN KEY (org_id) REFERENCES orgs(id)\"
             """)
  end

  test "raw SQL FK with parseable referenced table extracts it correctly" do
    # Note: if the referenced table can be parsed, it should be included in message
    results =
      judge([FKValidationScan], [big_events_table(), orgs()], """
      execute \"ALTER TABLE events ADD CONSTRAINT c FOREIGN KEY (org_id) REFERENCES public.orgs(id)\"
      """)

    assert [%Finding{check: :fk_validation_scan, severity: :error, message: msg}] = results
    # When referenced table is known, message should mention it
    assert msg =~ "writes to"
  end

  test "rule 5 on CRDB: FK add is online schema change, no finding" do
    crdb = %{"engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}}

    assert [] =
             judge(
               [FKValidationScan],
               [big_events_table(), orgs()],
               """
               alter table(:events) do
                 add :owner_org_id, references(:orgs)
               end
               """,
               snapshot: crdb
             )
  end
end
