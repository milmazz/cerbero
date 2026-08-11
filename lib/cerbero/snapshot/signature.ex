defmodule Cerbero.Snapshot.Signature do
  @moduledoc """
  Optional Ed25519 tamper-proofing for snapshots.

  The checksum detects corruption and hand-edits, but anyone who can
  commit can regenerate it. A signature binds the checksum to a private
  key: sign at export (`mix cerbero.snapshot --sign-key`), pin the public
  key(s) in `.cerbero.exs` `snapshot_verify_keys`, and a regenerated
  checksum no longer verifies — tampering needs the seed, not just commit
  access. Key distribution is deliberately minimal: verify keys are
  base64 strings committed in config; the seed lives wherever the
  exporting side keeps secrets. The signature signs the checksum string,
  which itself covers the canonical content (checksum and signature
  fields excluded), so sign-then-embed never invalidates the checksum.
  """

  @algorithm "ed25519"

  @doc "Generate a keypair: {public_key_base64, seed_base64}."
  @spec generate() :: {String.t(), String.t()}
  def generate do
    {pub, seed} = :crypto.generate_key(:eddsa, :ed25519)
    {Base.encode64(pub), Base.encode64(seed)}
  end

  @doc "Sign a stamped snapshot map (requires its \"checksum\")."
  @spec sign(map(), String.t()) :: map()
  def sign(%{"checksum" => "sha256:" <> _ = checksum} = stamped, seed_b64) do
    seed = Base.decode64!(seed_b64)
    {pub, ^seed} = :crypto.generate_key(:eddsa, :ed25519, seed)
    value = :crypto.sign(:eddsa, :none, checksum, [seed, :ed25519])

    Map.put(stamped, "signature", %{
      "algorithm" => @algorithm,
      "public_key" => Base.encode64(pub),
      "value" => Base.encode64(value)
    })
  end

  @doc """
  Verify a raw snapshot's signature. A present signature must always
  verify over the checksum (a broken one is a corruption signal even with
  no keys configured); configured verify keys additionally require the
  signature to exist and its key to be one of them.
  """
  @spec verify(map(), [String.t()]) :: :ok | {:error, term()}
  def verify(raw, verify_keys) do
    case Map.get(raw, "signature") do
      nil ->
        if verify_keys == [] do
          :ok
        else
          {:error,
           {:snapshot_unsigned,
            "snapshot_verify_keys is configured but the snapshot has no signature; " <>
              "re-export with --sign-key"}}
        end

      %{"algorithm" => @algorithm, "public_key" => pub_b64, "value" => value_b64} ->
        with {:ok, pub} <- decode64(pub_b64, "public_key"),
             {:ok, value} <- decode64(value_b64, "value"),
             :ok <- check_valid(raw["checksum"], value, pub) do
          check_trusted(pub_b64, verify_keys)
        end

      other ->
        {:error, {:signature_invalid, "unrecognized signature shape: #{inspect(other)}"}}
    end
  end

  defp decode64(b64, field) do
    with true <- is_binary(b64),
         {:ok, bytes} <- Base.decode64(b64) do
      {:ok, bytes}
    else
      _ -> {:error, {:signature_invalid, "signature.#{field} is not base64"}}
    end
  end

  defp check_valid("sha256:" <> _ = checksum, value, pub) do
    if :crypto.verify(:eddsa, :none, checksum, value, [pub, :ed25519]) do
      :ok
    else
      {:error, {:signature_invalid, "signature does not verify over the snapshot checksum"}}
    end
  end

  defp check_valid(_checksum, _value, _pub), do: {:error, {:signature_invalid, "no checksum to verify against"}}

  defp check_trusted(_pub_b64, []), do: :ok

  defp check_trusted(pub_b64, keys) do
    if pub_b64 in keys do
      :ok
    else
      {:error, {:signature_untrusted, "signing key #{pub_b64} is not in snapshot_verify_keys"}}
    end
  end
end
