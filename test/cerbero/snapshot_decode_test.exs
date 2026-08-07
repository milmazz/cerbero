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

  @tag :tmp_dir
  test "rejects unknown fields at any level", %{tmp_dir: tmp_dir} do
    for path_fun <- [
          &Map.put(&1, "surprise", "free text"),
          &put_in(&1, ["tables", Access.at(0), "surprise"], "free text"),
          &put_in(&1, ["tables", Access.at(0), "columns", Access.at(0), "surprise"], "x")
        ] do
      raw = @fixture |> File.read!() |> JSON.decode!()
      path = Path.join(tmp_dir, "unknown_field.json")
      Cerbero.Snapshot.write!(path_fun.(raw), path)
      assert {:error, {:unknown_fields, _path, ["surprise"]}} = Snapshot.load(path)
    end
  end

  @tag :tmp_dir
  test "rejects out-of-enum values", %{tmp_dir: tmp_dir} do
    raw = @fixture |> File.read!() |> JSON.decode!()
    bad = put_in(raw, ["engine", "name"], "mysql")
    path = Path.join(tmp_dir, "bad_enum.json")
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

  describe "engine floors" do
    defp with_engine(name, version, version_num) do
      Cerbero.Test.SnapshotBuilder.build(%{
        "engine" => %{"name" => name, "version" => version, "version_num" => version_num}
      })
    end

    test "PG below 13 is refused with a clear message" do
      assert {:error, {:unsupported_engine, msg}} =
               Snapshot.decode(with_engine("postgres", "12.9", 120_000))

      assert msg =~ "PostgreSQL >= 13"
    end

    test "PG 13 exactly is accepted" do
      assert {:ok, %Snapshot{}} = Snapshot.decode(with_engine("postgres", "13.0", 130_000))
    end

    test "CockroachDB below v23.1 is refused" do
      assert {:error, {:unsupported_engine, msg}} =
               Snapshot.decode(with_engine("cockroachdb", "v22.2.4", 22_204))

      assert msg =~ "CockroachDB >= v23.1"
    end

    test "CockroachDB v23.1 exactly is accepted" do
      assert {:ok, %Snapshot{}} = Snapshot.decode(with_engine("cockroachdb", "v23.1.0", 23_100))
    end
  end
end
