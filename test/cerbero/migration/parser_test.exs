defmodule Cerbero.Migration.ParserTest do
  use ExUnit.Case, async: true

  alias Cerbero.Migration
  alias Cerbero.Migration.Parser

  alias Cerbero.Operation.{
    AlterTable,
    CreateConstraint,
    CreateIndex,
    CreateTable,
    DropIndex,
    RawSQL,
    Unknown
  }

  defp ops!(source) do
    {:ok, %Migration{operations: ops}} = Parser.parse_string(source)
    ops
  end

  test "parses the committed corpus fixtures with versions and attributes" do
    {:ok, unsafe} =
      Parser.parse_file(
        "test/fixtures/migrations/unsafe/20260801000000_add_events_payload_index.exs"
      )

    assert unsafe.version == "20260801000000"
    assert unsafe.attrs.disable_ddl_transaction == false

    assert [
             %CreateIndex{
               table: "events",
               keys: ["org_id", "inserted_at"],
               concurrently: false,
               line: 5
             }
           ] =
             unsafe.operations

    {:ok, safe} =
      Parser.parse_file(
        "test/fixtures/migrations/safe/20260801000001_add_events_payload_index_concurrently.exs"
      )

    assert safe.attrs.disable_ddl_transaction and safe.attrs.disable_migration_lock
    assert [%CreateIndex{concurrently: true}] = safe.operations
  end

  test "create table with columns, references, and defaults" do
    assert [%CreateTable{table: "events_v2", columns: cols}] =
             ops!("""
             defmodule M do
               use Ecto.Migration
               def change do
                 create table(:events_v2) do
                   add :org_id, references(:orgs, on_delete: :nothing), null: false
                   add :flags, :integer, default: 0
                   add :inserted_at, :naive_datetime, default: fragment("now()")
                 end
               end
             end
             """)

    assert [
             %{
               name: "org_id",
               type: {:references, "orgs", [on_delete: :nothing]},
               opts: [null: false]
             },
             %{name: "flags", type: :integer, opts: [default: 0]},
             %{name: "inserted_at", type: :naive_datetime, opts: [default: {:fragment, "now()"}]}
           ] = cols
  end

  test "alter table: add/modify/remove" do
    assert [%AlterTable{table: "events", ops: ops}] =
             ops!("""
             defmodule M do
               use Ecto.Migration
               def up do
                 alter table(:events) do
                   add :score, :float
                   modify :org_id, :bigint, null: false
                   remove :legacy
                 end
               end
             end
             """)

    assert [
             {:add_column, "score", :float, []},
             {:modify_column, "org_id", :bigint, [null: false]},
             {:remove_column, "legacy"}
           ] = ops
  end

  test "unique_index, drop index, constraint" do
    assert [
             %CreateIndex{table: "events", unique: true},
             %DropIndex{table: "events", concurrently: true},
             %CreateConstraint{
               table: "products",
               name: "price_positive",
               check: "price > 0",
               validate: false
             }
           ] =
             ops!("""
             defmodule M do
               use Ecto.Migration
               def change do
                 create unique_index(:events, [:external_id])
                 drop index(:events, [:legacy], concurrently: true)
                 create constraint(:products, "price_positive", check: "price > 0", validate: false)
               end
             end
             """)
  end

  test "execute with a literal string is classified raw SQL; two-arg takes up only" do
    assert [%RawSQL{sql: "TRUNCATE events", classified: [%{class: :truncate}]}] =
             ops!("""
             defmodule M do
               use Ecto.Migration
               def up do
                 execute "TRUNCATE events", "SELECT 1"
               end
               def down do
               end
             end
             """)
  end

  test "dynamic constructs become Unknown, never silence, never execution" do
    assert [%Unknown{}] =
             ops!("""
             defmodule M do
               use Ecto.Migration
               def change do
                 for t <- [:a, :b], do: create(index(t, [:x]))
               end
             end
             """)

    assert [%Unknown{}] =
             ops!("""
             defmodule M do
               use Ecto.Migration
               def up do
                 execute build_sql()
               end
               defp build_sql, do: "DROP TABLE users"
             end
             """)
  end

  test "@cerbero_skip is parsed; empty reason is a parse error" do
    {:ok, m} =
      Parser.parse_string("""
      defmodule M do
        use Ecto.Migration
        @cerbero_skip [{:unsafe_index_creation, "maintenance window 2026-07-20, comms sent"}]
        def change do
          create index(:events, [:org_id])
        end
      end
      """)

    assert m.attrs.cerbero_skip == [
             {:unsafe_index_creation, "maintenance window 2026-07-20, comms sent"}
           ]

    assert {:error, {:empty_skip_reason, :unsafe_index_creation}} =
             Parser.parse_string("""
             defmodule M do
               use Ecto.Migration
               @cerbero_skip [{:unsafe_index_creation, ""}]
               def change do
               end
             end
             """)
  end

  test "find_module: prefers the module with `use Ecto.Migration` over a preceding helper module" do
    {:ok, m} =
      Parser.parse_string("""
      defmodule NotIt do
        def helper, do: :ok
      end

      defmodule AppRepo.Migrations.Real do
        use Ecto.Migration

        def change do
          create index(:events, [:org_id])
        end
      end
      """)

    assert m.module == "AppRepo.Migrations.Real"
    assert [%CreateIndex{table: "events", keys: ["org_id"]}] = m.operations
  end

  test "create_if_not_exists table is treated like create table" do
    assert [%CreateTable{table: "t", columns: [%{name: "org_id", type: :integer, opts: []}]}] =
             ops!("""
             defmodule M do
               use Ecto.Migration
               def change do
                 create_if_not_exists table(:t) do
                   add :org_id, :integer
                 end
               end
             end
             """)
  end

  test "create_if_not_exists constraint is treated like create constraint" do
    assert [%CreateConstraint{table: "t", name: "c", check: "x > 0", validate: true}] =
             ops!("""
             defmodule M do
               use Ecto.Migration
               def change do
                 create_if_not_exists constraint(:t, "c", check: "x > 0")
               end
             end
             """)
  end
end
