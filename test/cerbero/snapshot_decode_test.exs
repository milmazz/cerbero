defmodule Cerbero.SnapshotDecodeTest do
  use ExUnit.Case, async: true

  alias Cerbero.Snapshot
  import Cerbero.Test.SnapshotBuilder

  @fixture "test/fixtures/snapshots/huge_table.json"

  test "load returns a typed struct" do
    assert {:ok, %Snapshot{} = s} = Snapshot.load(@fixture)
    assert s.database == "app_prod"
    assert s.engine.name == :postgres
    assert s.engine.version_num == 150_004
    assert %DateTime{} = s.collected_at

    assert [%Snapshot.Table{name: "events"} = events, %Snapshot.Table{name: "orgs"}] =
             Enum.sort_by(s.tables, & &1.name)

    assert events.n_live_tup == 412_000_000
    assert [%{name: "id"}, %{name: "org_id"} = org_id | _] = events.columns
    refute is_nil(org_id.not_null)

    assert Enum.any?(
             events.constraints,
             &(&1.type == :foreign_key and &1.references.table == "public.orgs")
           )
  end

  test "rejects unknown fields at any level" do
    for path_fun <- [
          &Map.put(&1, "surprise", "free text"),
          &put_in(&1, ["tables", Access.at(0), "surprise"], "free text"),
          &put_in(&1, ["tables", Access.at(0), "columns", Access.at(0), "surprise"], "x")
        ] do
      raw = @fixture |> File.read!() |> JSON.decode!()
      path = Path.join(System.tmp_dir!(), "unknown_field.json")
      Cerbero.Snapshot.write!(path_fun.(raw), path)
      assert {:error, {:unknown_fields, _path, ["surprise"]}} = Snapshot.load(path)
    end
  end

  test "rejects out-of-enum values" do
    raw = @fixture |> File.read!() |> JSON.decode!()
    bad = put_in(raw, ["engine", "name"], "mysql")
    path = Path.join(System.tmp_dir!(), "bad_enum.json")
    Cerbero.Snapshot.write!(bad, path)
    assert {:error, {:invalid_value, _path, "mysql"}} = Snapshot.load(path)
  end

  describe "crash-safety regression tests" do
    test "returns error, not crash, when required 'tables' field is missing" do
      raw = build() |> Map.delete("tables")
      assert {:error, {:invalid_value, _, :not_a_list}} = Snapshot.decode(raw)
    end

    test "returns error, not crash, when 'columns' is nil" do
      raw =
        build(%{
          "tables" => [table("events", %{"columns" => nil})]
        })

      assert {:error, {:invalid_value, _, :not_a_list}} = Snapshot.decode(raw)
    end

    test "returns error, not crash, when generated column has invalid value" do
      raw =
        build(%{
          "tables" => [
            table("events", %{
              "columns" => [column("id", %{"generated" => "virtual"})]
            })
          ]
        })

      assert {:error, {:invalid_value, _, "virtual"}} = Snapshot.decode(raw)
    end

    test "returns error, not crash, when indexes is nil" do
      raw =
        build(%{
          "tables" => [table("events", %{"indexes" => nil})]
        })

      assert {:error, {:invalid_value, _, :not_a_list}} = Snapshot.decode(raw)
    end

    test "returns error, not crash, when constraints is nil" do
      raw =
        build(%{
          "tables" => [table("events", %{"constraints" => nil})]
        })

      assert {:error, {:invalid_value, _, :not_a_list}} = Snapshot.decode(raw)
    end

    test "returns error, not crash, when index keys is nil" do
      raw =
        build(%{
          "tables" => [
            table("events", %{
              "indexes" => [
                index("idx_id", ["id"], %{"keys" => nil})
              ]
            })
          ]
        })

      assert {:error, {:invalid_value, _, :not_a_list}} = Snapshot.decode(raw)
    end
  end
end
