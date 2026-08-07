defmodule Cerbero.SnapshotTest do
  use ExUnit.Case, async: true

  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Canonical

  @fixture "test/fixtures/snapshots/huge_table.json"

  test "decodes and checksum-verifies the v1 huge_table fixture" do
    assert {:ok, %Snapshot{} = snapshot} = Snapshot.load(@fixture)
    assert snapshot.database == "app_prod"
    assert snapshot.format_version == 1
    assert snapshot.engine.name == :postgres

    assert [%Snapshot.Table{name: "events"}, %Snapshot.Table{name: "orgs"}] =
             Enum.sort_by(snapshot.tables, & &1.name)
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

    test "sorts keys lexicographically for maps with >32 keys" do
      # Create a map with >32 deliberately-unsorted keys to escape BEAM flat-map
      # optimization (which keeps keys in term order = lexicographic for strings).
      # This forces the hash-map code path where order is not guaranteed.
      map_data =
        Map.new([
          {"k40", 40},
          {"k01", 1},
          {"k39", 39},
          {"k02", 2},
          {"k38", 38},
          {"k03", 3},
          {"k37", 37},
          {"k04", 4},
          {"k36", 36},
          {"k05", 5},
          {"k35", 35},
          {"k06", 6},
          {"k34", 34},
          {"k07", 7},
          {"k33", 33},
          {"k08", 8},
          {"k32", 32},
          {"k09", 9},
          {"k31", 31},
          {"k10", 10},
          {"k30", 30},
          {"k11", 11},
          {"k29", 29},
          {"k12", 12},
          {"k28", 28},
          {"k13", 13},
          {"k27", 27},
          {"k14", 14},
          {"k26", 26},
          {"k15", 15},
          {"k25", 25},
          {"k16", 16},
          {"k24", 24},
          {"k17", 17},
          {"k23", 23},
          {"k18", 18},
          {"k22", 22},
          {"k19", 19},
          {"k21", 21},
          {"k20", 20},
          {"k00", 0}
        ])

      encoded = Canonical.encode(map_data)

      # Extract all keys from the JSON output using a regex to find "key": pattern
      key_pattern = ~r/"(k\d{2})"/
      encoded_keys = Regex.scan(key_pattern, encoded) |> Enum.map(&Enum.at(&1, 1))

      # Verify keys appear in lexicographic order in the output
      sorted_keys = Enum.sort(encoded_keys)
      assert encoded_keys == sorted_keys
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
      assert {:error, {:format_too_new, 3, "upgrade cerbero"}} =
               reload_with(&Map.put(&1, "format_version", 3))
    end

    test "still accepts the v1 format (no precision field)" do
      assert {:ok, %Cerbero.Snapshot{format_version: 1, precision: :exact}} =
               reload_with(& &1)
    end

    test "refuses an older-than-supported format_version, telling the user to re-export" do
      assert {:error, {:format_too_old, 0, "re-export the snapshot"}} =
               reload_with(&Map.put(&1, "format_version", 0))
    end
  end

  describe "v2 precision field" do
    test "decodes precision as a closed enum, defaulting to :exact when absent" do
      raw = Cerbero.Test.SnapshotBuilder.build(%{"format_version" => 2})
      assert {:ok, %Cerbero.Snapshot{precision: :exact}} = Cerbero.Snapshot.decode(raw)

      bucketed =
        Cerbero.Test.SnapshotBuilder.build(%{
          "format_version" => 2,
          "precision" => "order_of_magnitude"
        })

      assert {:ok, %Cerbero.Snapshot{precision: :order_of_magnitude}} =
               Cerbero.Snapshot.decode(bucketed)
    end

    test "rejects out-of-enum precision values" do
      raw =
        Cerbero.Test.SnapshotBuilder.build(%{"format_version" => 2, "precision" => "fuzzy"})

      assert {:error, {:invalid_value, "$.precision", "fuzzy"}} = Cerbero.Snapshot.decode(raw)
    end
  end
end
