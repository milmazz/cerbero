defmodule Cerbero.Check.FKTest do
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.FKMissingIndex
  alias Cerbero.Check.FKValidationScan

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

  test "rule 6 sees references(...) declared inside create table" do
    assert [%Finding{check: :fk_missing_index, severity: :warning, message: msg}] =
             judge([FKMissingIndex], [orgs()], """
             create table(:events_v2) do
               add :owner_org_id, references(:orgs)
             end
             """)

    assert msg =~ "owner_org_id"
    assert msg =~ "public.orgs"
  end

  test "create-table FK with an index created in the same migration: silent" do
    assert [] =
             judge([FKMissingIndex], [orgs()], """
             create table(:events_v2) do
               add :owner_org_id, references(:orgs)
             end
             create index(:events_v2, [:owner_org_id])
             """)
  end

  test "create-table FK on a primary-key column is covered by the PK index" do
    assert [] =
             judge([FKMissingIndex], [orgs()], """
             create table(:org_prefs, primary_key: false) do
               add :org_id, references(:orgs), primary_key: true
             end
             """)
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

  test "create table + add FK to it in the same migration: silent (born-and-not-backfilled)" do
    assert [] =
             judge([FKValidationScan], [orgs()], """
             create table(:events_v2) do
               add :id, :bigint, primary_key: true
             end
             alter table(:events_v2) do
               add :owner_org_id, references(:orgs)
             end
             """)
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
