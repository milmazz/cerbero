defmodule Cerbero.CLI.Format.JSONTest do
  use ExUnit.Case, async: true

  alias Cerbero.CLI.Format.JSON, as: JSONFormat
  alias Cerbero.Finding

  @summary %{
    "errors" => 1,
    "infos" => 0,
    "snapshot" => nil,
    "warnings" => 0
  }

  defp finding(overrides) do
    struct!(
      %Finding{
        check: :unsafe_index_creation,
        severity: :error,
        message: "SHARE lock blocks writes",
        file: "priv/repo/migrations/20260801000000_add_index.exs",
        line: 5,
        relations: ["public.events"],
        engine: :postgres
      },
      overrides
    )
  end

  defp decoded(findings) do
    findings |> JSONFormat.render(@summary) |> JSON.decode!()
  end

  test "every finding carries a metadata object; empty metadata is {}" do
    %{"findings" => [f]} = decoded([finding(metadata: %{})])
    assert f["metadata"] == %{}
  end

  test "metadata atoms and nested maps encode as strings/objects" do
    %{"findings" => [f]} =
      decoded([
        finding(
          metadata: %{
            direction: :down,
            lock: :share,
            no_snapshot: true,
            skipped: %{via: :migration_attribute, reason: "reviewed by DBA"}
          }
        )
      ])

    assert f["metadata"] == %{
             "direction" => "down",
             "lock" => "share",
             "no_snapshot" => true,
             "skipped" => %{"via" => "migration_attribute", "reason" => "reviewed by DBA"}
           }
  end

  test "output stays canonical: byte-stable across calls, trailing newline" do
    out = JSONFormat.render([finding(metadata: %{lock: :share})], @summary)
    assert String.ends_with?(out, "\n")
    assert out == JSONFormat.render([finding(metadata: %{lock: :share})], @summary)
  end
end
