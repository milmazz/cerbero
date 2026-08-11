defmodule Cerbero.PrivacyTest do
  @moduledoc """
  The privacy allowlist. Adding any free-text-capable field to the
  snapshot REQUIRES touching this file — that is the point of it.
  Layers enforced here: strict schema (unknown fields rejected at every
  level), closed enums, and no expression-text fields anywhere.
  """
  use ExUnit.Case, async: true

  import Cerbero.Test.SnapshotBuilder

  alias Cerbero.Snapshot

  @committed_fixtures Path.wildcard("test/fixtures/snapshots/*.json")

  test "every committed fixture passes strict decode" do
    for path <- @committed_fixtures do
      assert {:ok, %Snapshot{}} = Snapshot.load(path), "fixture #{path} failed strict decode"
    end
  end

  test "builder output passes strict decode" do
    assert {:ok, %Snapshot{}} =
             Snapshot.decode(build(%{"tables" => [table("events"), table("orgs")]}))
  end

  # The invariant, mechanically: no field whose value could carry
  # expression text or literals exists in the schema. If this list of
  # string-valued fields grows, a human must justify the addition here.
  @string_fields_that_are_identifiers_or_enums ~w(
    cerbero_version database name schema type method partition_of table
    on_delete on_update is_not_null_check_on kind stats_provenance version
    collected_at stats_reset last_analyze last_autoanalyze checksum
  )

  test "all string-valued leaves in the fixture are identifier/enum/timestamp fields" do
    raw = "test/fixtures/snapshots/huge_table.json" |> File.read!() |> JSON.decode!()

    for {key_path, value} <- string_leaves(raw), is_binary(value) do
      key = List.last(key_path)

      assert key in @string_fields_that_are_identifiers_or_enums or is_integer(key),
             "unexpected string field #{inspect(key_path)} — privacy review required"
    end
  end

  defp string_leaves(map, path \\ [])

  defp string_leaves(map, path) when is_map(map), do: Enum.flat_map(map, fn {k, v} -> string_leaves(v, path ++ [k]) end)

  defp string_leaves(list, path) when is_list(list),
    do: list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> string_leaves(v, path ++ [i]) end)

  defp string_leaves(v, path) when is_binary(v), do: [{path, v}]
  defp string_leaves(_v, _path), do: []
end
