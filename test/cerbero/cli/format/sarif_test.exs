defmodule Cerbero.CLI.Format.SARIFTest do
  use ExUnit.Case, async: true

  alias Cerbero.CLI.Format.SARIF
  alias Cerbero.Finding

  @summary %{
    "errors" => 1,
    "infos" => 0,
    "snapshot" => %{"database" => "app_prod"},
    "warnings" => 0
  }

  defp doc(findings, snapshot_path \\ nil) do
    findings |> SARIF.render(@summary, snapshot_path) |> JSON.decode!()
  end

  defp run(doc), do: hd(doc["runs"])
  defp results(doc), do: run(doc)["results"]

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

  test "document envelope: schema, version, tool driver" do
    d = doc([finding([])])

    assert d["version"] == "2.1.0"
    assert d["$schema"] =~ "sarif-schema-2.1.0"

    driver = run(d)["tool"]["driver"]
    assert driver["name"] == "cerbero"
    assert driver["version"] == to_string(Application.spec(:cerbero, :vsn))
    assert driver["semanticVersion"] == driver["version"]
    assert driver["informationUri"] == "https://github.com/milmazz/cerbero"
  end

  test "severity maps to SARIF level: error/warning/note; infos are not dropped" do
    [e, w, i] =
      results(
        doc([
          finding(severity: :error, line: 1),
          finding(severity: :warning, line: 2),
          finding(severity: :info, line: 3)
        ])
      )

    assert e["level"] == "error"
    assert w["level"] == "warning"
    assert i["level"] == "note"
  end

  test "results are sorted by file, line, check" do
    [first, second] =
      results(
        doc([
          finding(file: "b.exs", line: 1),
          finding(file: "a.exs", line: 9)
        ])
      )

    assert get_in(first, [
             "locations",
             Access.at(0),
             "physicalLocation",
             "artifactLocation",
             "uri"
           ]) ==
             "a.exs"

    assert get_in(second, [
             "locations",
             Access.at(0),
             "physicalLocation",
             "artifactLocation",
             "uri"
           ]) ==
             "b.exs"
  end

  test "file finding gets a physical location with region and %SRCROOT% base" do
    [r] = results(doc([finding([])]))

    assert r["locations"] == [
             %{
               "physicalLocation" => %{
                 "artifactLocation" => %{
                   "uri" => "priv/repo/migrations/20260801000000_add_index.exs",
                   "uriBaseId" => "%SRCROOT%"
                 },
                 "region" => %{"startLine" => 5}
               }
             }
           ]
  end

  test "nil line omits the region" do
    [r] = results(doc([finding(line: nil)]))
    [loc] = r["locations"]
    refute Map.has_key?(loc["physicalLocation"], "region")
  end

  test "global finding anchors to the snapshot file at line 1" do
    [r] = results(doc([finding(file: nil, line: nil)], "priv/repo/cerbero_snapshot.json"))
    [loc] = r["locations"]

    assert loc["physicalLocation"]["artifactLocation"]["uri"] ==
             "priv/repo/cerbero_snapshot.json"

    assert loc["physicalLocation"]["region"] == %{"startLine" => 1}
  end

  test "global finding without a snapshot path has no locations" do
    [r] = results(doc([finding(file: nil, line: nil)], nil))
    refute Map.has_key?(r, "locations")
  end

  test "rules: distinct sorted ids with descriptions; ruleIndex agrees with ruleId" do
    d =
      doc(
        [
          finding(check: :snapshot_health, file: nil, line: nil),
          finding([]),
          finding(line: 9)
        ],
        "snap.json"
      )

    rules = run(d)["tool"]["driver"]["rules"]
    assert Enum.map(rules, & &1["id"]) == ["snapshot_health", "unsafe_index_creation"]

    for rule <- rules do
      assert rule["name"] == rule["id"]
      assert rule["shortDescription"]["text"] != rule["id"]
    end

    for r <- results(d) do
      assert Enum.at(rules, r["ruleIndex"])["id"] == r["ruleId"]
    end
  end

  test "an unknown (third-party) check id falls back to the id as its description" do
    d = doc([finding(check: :my_custom_check)])
    [rule] = run(d)["tool"]["driver"]["rules"]
    assert rule["shortDescription"]["text"] == "my_custom_check"
  end

  test "relations and engine ride in result properties; engine omitted when nil" do
    [with_engine] = results(doc([finding([])]))

    assert with_engine["properties"] == %{
             "engine" => "postgres",
             "relations" => ["public.events"]
           }

    [without_engine] = results(doc([finding(engine: nil, relations: [])]))
    assert without_engine["properties"] == %{"relations" => []}
  end

  test "run properties carry the summary verbatim" do
    assert run(doc([finding([])]))["properties"] == %{"summary" => @summary}
  end

  test "output is canonical: trailing newline, byte-stable across calls" do
    out = SARIF.render([finding([])], @summary, nil)
    assert String.ends_with?(out, "\n")
    assert out == SARIF.render([finding([])], @summary, nil)
  end
end
