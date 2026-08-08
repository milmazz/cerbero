defmodule Cerbero.SnapshotSignatureTest do
  use ExUnit.Case, async: true

  import Cerbero.Test.SnapshotBuilder

  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Canonical
  alias Cerbero.Snapshot.Signature

  defp write_signed(tmp_dir, seed_b64) do
    signed = Signature.sign(build(), seed_b64)
    path = Path.join(tmp_dir, "signed.json")
    Snapshot.write!(signed, path)
    path
  end

  @tag :tmp_dir
  test "sign -> load with the matching verify key succeeds", %{tmp_dir: tmp_dir} do
    {pub, seed} = Signature.generate()
    path = write_signed(tmp_dir, seed)

    assert {:ok, %Snapshot{}} = Snapshot.load(path, verify_keys: [pub])
  end

  @tag :tmp_dir
  test "a signature from an untrusted key is rejected", %{tmp_dir: tmp_dir} do
    {_pub, seed} = Signature.generate()
    {other_pub, _other_seed} = Signature.generate()
    path = write_signed(tmp_dir, seed)

    assert {:error, {:signature_untrusted, _}} = Snapshot.load(path, verify_keys: [other_pub])
  end

  @tag :tmp_dir
  test "tampering after signing is caught even when the checksum is regenerated", %{
    tmp_dir: tmp_dir
  } do
    {pub, seed} = Signature.generate()
    signed = Signature.sign(build(), seed)

    tampered = signed |> Map.put("database", "prod_evil") |> Snapshot.stamp()
    path = Path.join(tmp_dir, "tampered.json")
    File.write!(path, Canonical.encode(tampered))

    assert {:error, {:signature_invalid, _}} = Snapshot.load(path, verify_keys: [pub])
  end

  @tag :tmp_dir
  test "verify keys configured but the snapshot is unsigned: rejected", %{tmp_dir: tmp_dir} do
    {pub, _seed} = Signature.generate()
    path = Path.join(tmp_dir, "unsigned.json")
    Snapshot.write!(build(), path)

    assert {:error, {:snapshot_unsigned, _}} = Snapshot.load(path, verify_keys: [pub])
  end

  @tag :tmp_dir
  test "no verify keys configured: unsigned and signed snapshots both load", %{tmp_dir: tmp_dir} do
    {_pub, seed} = Signature.generate()

    unsigned = Path.join(tmp_dir, "unsigned.json")
    Snapshot.write!(build(), unsigned)
    assert {:ok, %Snapshot{}} = Snapshot.load(unsigned)

    signed = write_signed(tmp_dir, seed)
    assert {:ok, %Snapshot{}} = Snapshot.load(signed)
  end

  @tag :tmp_dir
  test "a corrupted signature on an otherwise-valid snapshot is an error even without keys", %{
    tmp_dir: tmp_dir
  } do
    {_pub, seed} = Signature.generate()
    signed = Signature.sign(build(), seed)
    corrupted = put_in(signed["signature"]["value"], Base.encode64(:crypto.strong_rand_bytes(64)))

    path = Path.join(tmp_dir, "corrupted.json")
    File.write!(path, Canonical.encode(corrupted))

    assert {:error, {:signature_invalid, _}} = Snapshot.load(path)
  end

  test "signing preserves the checksum: stamp is idempotent over the signature field" do
    {_pub, seed} = Signature.generate()
    stamped = build()
    signed = Signature.sign(stamped, seed)

    assert Snapshot.compute_checksum(signed) == stamped["checksum"]
  end
end
