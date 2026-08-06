defmodule Cerbero.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cerbero.Migration.Parser
  alias Cerbero.Operation, as: Op
  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Canonical

  defp json_term do
    leaf =
      one_of([
        integer(),
        float(min: -1.0e6, max: 1.0e6),
        boolean(),
        string(:alphanumeric),
        constant(nil)
      ])

    tree(leaf, fn child ->
      one_of([
        list_of(child, max_length: 4),
        map_of(string(:alphanumeric, min_length: 1), child, max_length: 4)
      ])
    end)
  end

  property "canonical encode/decode round-trips and checksum is key-order independent" do
    check all(term <- map_of(string(:alphanumeric, min_length: 1), json_term(), max_length: 6)) do
      encoded = Canonical.encode(term)
      assert JSON.decode!(encoded) == JSON.decode!(Canonical.encode(JSON.decode!(encoded)))

      shuffled = term |> Enum.shuffle() |> Map.new()

      assert Snapshot.compute_checksum(Map.put(term, "checksum", nil)) ==
               Snapshot.compute_checksum(Map.put(shuffled, "checksum", nil))
    end
  end

  @bodies [
    "create index(:t, [:a])",
    "drop index(:t, [:a])",
    "alter table(:t) do\n add :x, :integer\n end",
    "execute \"UPDATE t SET x = 1\"",
    "create table(:t) do\n add :x, :map\n end",
    "rename table(:a), to: table(:b)",
    "for x <- [1], do: x",
    "execute dynamic_sql()",
    "flush()"
  ]

  property "parser totality: arbitrary combinations never crash, always yield operations or Unknown" do
    check all(bodies <- list_of(member_of(@bodies), min_length: 1, max_length: 6)) do
      source =
        "defmodule P do\n use Ecto.Migration\n def change do\n #{Enum.join(bodies, "\n")}\n end\nend"

      case Parser.parse_string(source) do
        {:ok, migration} ->
          for op <- migration.operations do
            assert op.__struct__ in [
                     Op.CreateTable,
                     Op.AlterTable,
                     Op.CreateIndex,
                     Op.DropIndex,
                     Op.CreateConstraint,
                     Op.DropTable,
                     Op.RenameOp,
                     Op.RawSQL,
                     Op.Unknown
                   ]
          end

        {:error, _} ->
          :ok
      end
    end
  end
end
