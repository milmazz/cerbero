defmodule Cerbero.SnapshotTest do
  use ExUnit.Case, async: true

  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Canonical

  @fixture "test/fixtures/snapshots/huge_table.json"

  test "decodes and checksum-verifies the v1 huge_table fixture" do
    assert {:ok, snapshot} = Snapshot.load(@fixture)
    assert snapshot["database"] == "app_prod"
    assert snapshot["format_version"] == 1
    assert snapshot["engine"]["name"] == "postgres"
    assert [%{"name" => "events"}, %{"name" => "orgs"}] =
             Enum.sort_by(snapshot["tables"], & &1["name"])
  end

  test "fixture bytes are already canonical (re-encode is byte-identical)" do
    raw = @fixture |> File.read!() |> JSON.decode!()
    assert Canonical.encode(raw) == File.read!(@fixture)
  end

  test "load rejects a corrupted snapshot with a checksum error" do
    raw = @fixture |> File.read!() |> JSON.decode!()
    tampered = put_in(raw, ["tables", Access.at(0), "n_live_tup"], 1)
    path = Path.join(System.tmp_dir!(), "tampered.json")
    File.write!(path, Canonical.encode(tampered))
    assert {:error, {:checksum_mismatch, _expected, _actual}} = Snapshot.load(path)
  end

  describe "canonical encoding" do
    test "sorts keys, indents 2 spaces, ends with LF" do
      assert Canonical.encode(%{"b" => 1, "a" => [true, nil]}) ==
               """
               {
                 "a": [
                   true,
                   null
                 ],
                 "b": 1
               }
               """
    end

    test "checksum is independent of input key order" do
      a = %{"x" => 1, "y" => %{"k" => [1, 2]}, "checksum" => nil}
      b = %{"y" => %{"k" => [1, 2]}, "checksum" => nil, "x" => 1}
      assert Snapshot.compute_checksum(a) == Snapshot.compute_checksum(b)
    end
  end

  describe "format version gate" do
    defp reload_with(fun) do
      raw = "test/fixtures/snapshots/huge_table.json" |> File.read!() |> JSON.decode!()
      path = Path.join(System.tmp_dir!(), "versioned.json")
      Cerbero.Snapshot.write!(fun.(raw), path)
      Cerbero.Snapshot.load(path)
    end

    test "refuses a newer format_version, telling the user to upgrade" do
      assert {:error, {:format_too_new, 2, "upgrade cerbero"}} =
               reload_with(&Map.put(&1, "format_version", 2))
    end

    test "refuses an older-than-supported format_version, telling the user to re-export" do
      assert {:error, {:format_too_old, 0, "re-export the snapshot"}} =
               reload_with(&Map.put(&1, "format_version", 0))
    end
  end
end
