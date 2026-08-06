defmodule Cerbero.Snapshot.Canonical do
  @moduledoc """
  Canonical JSON: object keys sorted lexicographically, 2-space indent,
  LF endings, trailing newline. The checksum is computed over these bytes,
  and stable ordering is what makes PR diffs reviewable, so this encoder
  must stay byte-stable across Elixir/OTP versions.
  """

  @spec encode(term()) :: binary()
  def encode(term), do: IO.iodata_to_binary([do_encode(term, 0), "\n"])

  defp do_encode(map, _depth) when map == %{}, do: "{}"

  defp do_encode(map, depth) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map(fn {k, v} ->
        [pad(depth + 1), JSON.encode!(to_string(k)), ": ", do_encode(v, depth + 1)]
      end)
      |> Enum.intersperse(",\n")

    ["{\n", inner, "\n", pad(depth), "}"]
  end

  defp do_encode([], _depth), do: "[]"

  defp do_encode(list, depth) when is_list(list) do
    inner =
      list
      |> Enum.map(fn v -> [pad(depth + 1), do_encode(v, depth + 1)] end)
      |> Enum.intersperse(",\n")

    ["[\n", inner, "\n", pad(depth), "]"]
  end

  defp do_encode(scalar, _depth), do: JSON.encode!(scalar)

  defp pad(depth), do: String.duplicate("  ", depth)
end
