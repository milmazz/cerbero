defmodule Cerbero.Snapshot do
  @moduledoc """
  The snapshot artifact: decode, verify, canonically re-encode.

  The checksum detects corruption and hand-edits — anyone who can commit
  can regenerate it; it is not tamper-proofing.
  """

  alias Cerbero.Snapshot.Canonical

  @format_version 1
  @min_supported 1

  def format_version, do: @format_version

  @spec compute_checksum(map()) :: String.t()
  def compute_checksum(map) when is_map(map) do
    canonical = Canonical.encode(Map.put(map, "checksum", nil))
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)
  end

  @spec stamp(map()) :: map()
  def stamp(map), do: Map.put(map, "checksum", compute_checksum(map))

  @spec write!(map(), Path.t()) :: :ok
  def write!(map, path), do: File.write!(path, Canonical.encode(stamp(map)))

  @spec load(Path.t()) :: {:ok, map()} | {:error, term()}
  def load(path) do
    with {:ok, bytes} <- read(path),
         {:ok, raw} <- decode_json(bytes),
         :ok <- verify_checksum(raw),
         :ok <- gate_version(raw) do
      {:ok, raw}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  defp decode_json(bytes) do
    case JSON.decode(bytes) do
      {:ok, raw} when is_map(raw) -> {:ok, raw}
      _ -> {:error, :invalid_json}
    end
  end

  defp verify_checksum(%{"checksum" => "sha256:" <> _ = embedded} = raw) do
    case compute_checksum(raw) do
      ^embedded -> :ok
      actual -> {:error, {:checksum_mismatch, embedded, actual}}
    end
  end

  defp verify_checksum(_), do: {:error, :missing_checksum}

  defp gate_version(%{"format_version" => v}) when is_integer(v) do
    cond do
      v > @format_version -> {:error, {:format_too_new, v, "upgrade cerbero"}}
      v < @min_supported -> {:error, {:format_too_old, v, "re-export the snapshot"}}
      true -> :ok
    end
  end

  defp gate_version(_), do: {:error, :missing_format_version}
end
