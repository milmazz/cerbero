defmodule Cerbero.SnapshotTest do
  use ExUnit.Case, async: true

  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Canonical
  alias Cerbero.Snapshot.Signature
  alias Cerbero.Test.SnapshotBuilder

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

  @tag :tmp_dir
  test "load rejects a corrupted snapshot with a checksum error", %{tmp_dir: tmp_dir} do
    raw = @fixture |> File.read!() |> JSON.decode!()
    tampered = put_in(raw, ["tables", Access.at(0), "n_live_tup"], 1)
    path = Path.join(tmp_dir, "tampered.json")
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
      encoded_keys = key_pattern |> Regex.scan(encoded) |> Enum.map(&Enum.at(&1, 1))

      # Verify keys appear in lexicographic order in the output
      sorted_keys = Enum.sort(encoded_keys)
      assert encoded_keys == sorted_keys
    end
  end

  describe "format version gate" do
    # Pre-release collapse: precision and signature are part of the v1
    # baseline — there are no published readers of older formats to protect.
    test "the current format version is 1" do
      assert Snapshot.format_version() == 1
    end

    defp reload_with(tmp_dir, fun) do
      raw = "test/fixtures/snapshots/huge_table.json" |> File.read!() |> JSON.decode!()
      path = Path.join(tmp_dir, "versioned.json")
      Snapshot.write!(fun.(raw), path)
      Snapshot.load(path)
    end

    @tag :tmp_dir
    test "refuses a newer format_version, telling the user to upgrade", %{tmp_dir: tmp_dir} do
      too_new = Snapshot.format_version() + 1

      assert {:error, {:format_too_new, ^too_new, "upgrade cerbero"}} =
               reload_with(tmp_dir, &Map.put(&1, "format_version", too_new))
    end

    @tag :tmp_dir
    test "still accepts the v1 format (no precision field)", %{tmp_dir: tmp_dir} do
      assert {:ok, %Snapshot{format_version: 1, precision: :exact}} =
               reload_with(tmp_dir, & &1)
    end

    @tag :tmp_dir
    test "refuses an older-than-supported format_version, telling the user to re-export", %{
      tmp_dir: tmp_dir
    } do
      assert {:error, {:format_too_old, 0, "re-export the snapshot"}} =
               reload_with(tmp_dir, &Map.put(&1, "format_version", 0))
    end
  end

  describe "write_stamped!/2" do
    @tag :tmp_dir
    test "writes an already-stamped map byte-identically to write!/2", %{tmp_dir: tmp_dir} do
      stamped = SnapshotBuilder.build(%{})

      stamped_path = Path.join(tmp_dir, "stamped.json")
      restamped_path = Path.join(tmp_dir, "restamped.json")
      Snapshot.write_stamped!(stamped, stamped_path)
      Snapshot.write!(stamped, restamped_path)

      assert File.read!(stamped_path) == File.read!(restamped_path)
      assert {:ok, %Snapshot{}} = Snapshot.load(stamped_path)
    end

    @tag :tmp_dir
    test "does NOT re-stamp: a wrong embedded checksum is written verbatim", %{tmp_dir: tmp_dir} do
      # This is the contract split from write!/2: signature tests mutate
      # stamped maps and rely on write! re-stamping; write_stamped! must
      # instead preserve the map exactly (the CLI signs over the stamped
      # checksum — a re-stamp there would be wasted work, a rewrite here
      # would mask corruption).
      bogus = "sha256:" <> String.duplicate("0", 64)
      tampered = Map.put(SnapshotBuilder.build(%{}), "checksum", bogus)

      path = Path.join(tmp_dir, "tampered.json")
      Snapshot.write_stamped!(tampered, path)

      assert File.read!(path) =~ bogus
      assert {:error, {:checksum_mismatch, ^bogus, _actual}} = Snapshot.load(path)
    end

    @tag :tmp_dir
    test "stamp -> sign -> write_stamped! round-trips through load with verify keys", %{
      tmp_dir: tmp_dir
    } do
      # The CLI's signed-export pipeline, end to end.
      {pub, seed} = Signature.generate()
      stamped = SnapshotBuilder.build(%{})
      path = Path.join(tmp_dir, "signed.json")

      stamped
      |> Signature.sign(seed)
      |> Snapshot.write_stamped!(path)

      assert {:ok, %Snapshot{}} = Snapshot.load(path, verify_keys: [pub])
    end

    @tag :tmp_dir
    test "refuses an unstamped map loudly", %{tmp_dir: tmp_dir} do
      raw = Map.delete(SnapshotBuilder.build(%{}), "checksum")
      path = Path.join(tmp_dir, "unstamped.json")

      assert_raise ArgumentError, ~r/stamped/, fn -> Snapshot.write_stamped!(raw, path) end
      refute File.exists?(path)
    end
  end

  describe "precision field" do
    test "decodes precision as a closed enum, defaulting to :exact when absent" do
      raw = SnapshotBuilder.build(%{})
      assert {:ok, %Snapshot{precision: :exact}} = Snapshot.decode(raw)

      bucketed =
        SnapshotBuilder.build(%{"precision" => "order_of_magnitude"})

      assert {:ok, %Snapshot{precision: :order_of_magnitude}} =
               Snapshot.decode(bucketed)
    end

    test "rejects out-of-enum precision values" do
      raw = SnapshotBuilder.build(%{"precision" => "fuzzy"})

      assert {:error, {:invalid_value, "$.precision", "fuzzy"}} = Snapshot.decode(raw)
    end
  end
end
