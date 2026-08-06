defmodule Cerbero.CatalogOverlayTest do
  use ExUnit.Case, async: true

  alias Cerbero.Catalog
  alias Cerbero.Migration.Parser
  import Cerbero.Test.SnapshotBuilder

  defp base_catalog(tables \\ []) do
    snapshot = build_snapshot(%{"tables" => tables})

    staleness = %Cerbero.Snapshot.Staleness{
      age_days: 1,
      scale_mode: :exact,
      threshold_multiplier: 1.0
    }

    Catalog.from_snapshot(snapshot, staleness)
  end

  defp apply_source(cat, body) do
    {:ok, m} =
      Parser.parse_string(
        "defmodule M do\n use Ecto.Migration\n def change do\n #{body}\n end\nend"
      )

    Catalog.apply_migration(cat, m)
  end

  test "created table is known, born, and :zero scale" do
    cat =
      apply_source(base_catalog(), """
      create table(:events_v2) do
        add :org_id, :bigint
      end
      """)

    assert Catalog.known?(cat, "events_v2")
    assert Catalog.born?(cat, "events_v2")
    assert Catalog.scale(cat, "events_v2") == :zero
    assert %{name: "org_id"} = Catalog.column(cat, "events_v2", "org_id")
  end

  test "created-then-backfilled table is NOT empty by construction (revocation)" do
    cat =
      base_catalog()
      |> apply_source("create table(:events_v2) do\n add :x, :bigint\n end")
      |> apply_source(~s|execute "INSERT INTO events_v2 SELECT * FROM events"|)

    assert Catalog.backfilled?(cat, "events_v2")
    assert Catalog.scale(cat, "events_v2") == :unknown
  end

  test "DSL-created index becomes visible (rule 6 consumes this)" do
    cat =
      base_catalog([table("events")])
      |> apply_source("create index(:events, [:org_id])")

    assert Catalog.has_index_leading_on?(cat, "events", "org_id")
  end

  test "the raw-SQL NOT NULL two-step is recognized: NOT VALID check + VALIDATE" do
    cat =
      base_catalog([table("events", %{"columns" => [column("org_id")]})])
      |> apply_source(
        ~s|execute "ALTER TABLE events ADD CONSTRAINT org_id_nn CHECK (org_id IS NOT NULL) NOT VALID"|
      )

    refute Catalog.validated_not_null_check?(cat, "events", "org_id")

    cat = apply_source(cat, ~s|execute "ALTER TABLE events VALIDATE CONSTRAINT org_id_nn"|)
    assert Catalog.validated_not_null_check?(cat, "events", "org_id")
  end

  test "alter table add/remove/modify columns updates the model" do
    cat =
      base_catalog([table("events", %{"columns" => [column("org_id"), column("legacy")]})])
      |> apply_source("""
      alter table(:events) do
        add :score, :float
        modify :org_id, :bigint, null: false
        remove :legacy
      end
      """)

    assert %{name: "score"} = Catalog.column(cat, "events", "score")
    assert %{not_null: true} = Catalog.column(cat, "events", "org_id")
    assert Catalog.column(cat, "events", "legacy") == nil
  end

  test "raw-SQL created table is also born" do
    cat = apply_source(base_catalog(), ~s|execute "CREATE TABLE events_v2 (id bigint)"|)
    assert Catalog.born?(cat, "events_v2")
  end

  test "dropped table disappears" do
    cat = base_catalog([table("legacy")]) |> apply_source("drop table(:legacy)")
    refute Catalog.known?(cat, "legacy")
  end

  test "drop-and-recreate clears backfilled mark (regression)" do
    cat =
      base_catalog()
      |> apply_source("create table(:events_v2) do\n add :x, :bigint\n end")
      |> apply_source(~s|execute "INSERT INTO events_v2 SELECT * FROM events"|)
      |> apply_source("drop table(:events_v2)")
      |> apply_source("create table(:events_v2) do\n add :x, :bigint\n end")

    assert Catalog.known?(cat, "events_v2")
    assert Catalog.born?(cat, "events_v2")
    refute Catalog.backfilled?(cat, "events_v2")
    assert Catalog.scale(cat, "events_v2") == :zero
  end
end
