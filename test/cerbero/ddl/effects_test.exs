defmodule Cerbero.DDL.EffectsTest do
  use ExUnit.Case, async: true

  alias Cerbero.DDL.{Effect, Effects}
  alias Cerbero.Migration.Parser

  defp effects(source) do
    {:ok, migration} = Parser.parse_string(source)
    Enum.flat_map(migration.operations, &Effects.derive(&1, :postgres, 150_004))
  end

  defp migration(body),
    do: "defmodule M do\n use Ecto.Migration\n def change do\n #{body}\n end\nend"

  test "non-concurrent index: SHARE + full_scan on the target" do
    assert [
             %Effect{
               class: :create_index,
               lock: :share,
               cost: :full_scan,
               relations: [target: "events"]
             }
           ] =
             effects(migration("create index(:events, [:org_id])"))
  end

  test "add column with constant vs volatile default vs plain" do
    assert [
             %Effect{class: :add_column_constant_default, cost: :metadata_only},
             %Effect{class: :add_column_volatile_default, cost: :rewrite},
             %Effect{class: :add_column_constant_default}
           ] =
             effects(
               migration("""
               alter table(:events) do
                 add :flags, :integer, default: 0
                 add :token, :uuid, default: fragment("gen_random_uuid()")
                 add :note, :text
               end
               """)
             )
  end

  test "add FK touches referencing and referenced" do
    assert [
             %Effect{
               class: :add_foreign_key,
               lock: :share_row_exclusive,
               relations: [target: "events", referenced: "orgs"]
             }
           ] =
             effects(
               migration("""
               alter table(:events) do
                 add :org_id, references(:orgs)
               end
               """)
             )
  end

  test "modify to NOT NULL emits set_not_null; type change emits alter_column_type" do
    assert [
             %Effect{class: :alter_column_type, cost: :rewrite},
             %Effect{class: :set_not_null, cost: :full_scan}
           ] =
             effects(
               migration("""
               alter table(:events) do
                 modify :org_id, :bigint, null: false
               end
               """)
             )
             |> Enum.sort_by(& &1.class)
  end

  test "raw SQL derives through its classification" do
    assert [
             %Effect{
               class: :add_check_not_valid,
               cost: :metadata_only,
               relations: [target: "events"]
             }
           ] =
             effects(
               migration(
                 ~s|execute "ALTER TABLE events ADD CONSTRAINT c CHECK (org_id IS NOT NULL) NOT VALID"|
               )
             )
  end

  test "Unknown operations derive to the conservative default with unmapped: true" do
    assert [%Effect{lock: :access_exclusive, cost: :rewrite, unmapped: true}] =
             effects(migration("for t <- [:a], do: create(index(t, [:x]))"))
  end

  test "version-conditional note: PG version is named" do
    [%Effect{notes: notes}] = effects(migration("create index(:events, [:org_id])"))
    assert Enum.any?(notes, &(&1 =~ "assuming PG 15"))
  end

  test "FK column with volatile default emits both add_foreign_key and add_column_volatile_default" do
    assert [
             %Effect{class: :add_foreign_key, lock: :share_row_exclusive},
             %Effect{class: :add_column_volatile_default, cost: :rewrite}
           ] =
             effects(
               migration("""
               alter table(:events) do
                 add :org_id, references(:orgs), default: fragment("gen_random_uuid()")
               end
               """)
             )
  end

  test "FK column with generated option emits both add_foreign_key and add_column_generated_stored" do
    assert [
             %Effect{class: :add_foreign_key, lock: :share_row_exclusive},
             %Effect{class: :add_column_generated_stored, cost: :rewrite}
           ] =
             effects(
               migration("""
               alter table(:events) do
                 add :org_id, references(:orgs), generated: :always
               end
               """)
             )
  end
end
