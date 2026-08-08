defmodule Cerbero.CLI.Format.SARIF do
  @moduledoc """
  SARIF 2.1.0 output: a mechanical adapter over the findings list for
  GitHub code-scanning annotations. Global findings (no file) anchor to
  the committed snapshot artifact — the file they are actually about.
  """

  alias Cerbero.Finding
  alias Cerbero.Snapshot.Canonical

  @schema "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json"
  @information_uri "https://github.com/milmazz/cerbero"

  # `descriptions` maps rule id => one-line description. The catalog is the
  # caller's (the CLI assembles it from the check modules' `description/0`),
  # not this formatter's — SARIF stays a mechanical adapter. An id without
  # an entry falls back to the id itself.
  @spec render([Finding.t()], map(), String.t() | nil, %{String.t() => String.t()}) :: String.t()
  def render(findings, summary, snapshot_path, descriptions \\ %{}) do
    findings =
      Enum.sort_by(findings, &{&1.file || "", &1.line || 0, Atom.to_string(&1.check)})

    rule_ids =
      findings |> Enum.map(&Atom.to_string(&1.check)) |> Enum.uniq() |> Enum.sort()

    rule_index = rule_ids |> Enum.with_index() |> Map.new()

    Canonical.encode(%{
      "$schema" => @schema,
      "version" => "2.1.0",
      "runs" => [
        %{
          "tool" => %{"driver" => driver(rule_ids, descriptions)},
          "results" => Enum.map(findings, &result(&1, rule_index, snapshot_path)),
          "properties" => %{"summary" => summary}
        }
      ]
    })
  end

  defp driver(rule_ids, descriptions) do
    %{
      "informationUri" => @information_uri,
      "name" => "cerbero",
      "rules" => Enum.map(rule_ids, &rule(&1, descriptions)),
      "semanticVersion" => version(),
      "version" => version()
    }
  end

  defp rule(id, descriptions) do
    %{
      "id" => id,
      "name" => id,
      "shortDescription" => %{"text" => Map.get(descriptions, id, id)}
    }
  end

  defp version, do: :cerbero |> Application.spec(:vsn) |> to_string()

  defp result(%Finding{} = f, rule_index, snapshot_path) do
    id = Atom.to_string(f.check)

    base = %{
      "ruleId" => id,
      "ruleIndex" => Map.fetch!(rule_index, id),
      "level" => level(f.severity),
      "message" => %{"text" => f.message},
      "properties" => properties(f)
    }

    case location(f, snapshot_path) do
      nil -> base
      loc -> Map.put(base, "locations", [loc])
    end
  end

  defp level(:error), do: "error"
  defp level(:warning), do: "warning"
  defp level(:info), do: "note"

  defp properties(%Finding{relations: relations, engine: nil}), do: %{"relations" => relations}

  defp properties(%Finding{relations: relations, engine: engine}),
    do: %{"engine" => Atom.to_string(engine), "relations" => relations}

  defp location(%Finding{file: nil}, nil), do: nil
  defp location(%Finding{file: nil}, snapshot_path), do: physical(snapshot_path, 1)
  defp location(%Finding{file: file, line: line}, _snapshot_path), do: physical(file, line)

  defp physical(uri, line) do
    location = %{"artifactLocation" => %{"uri" => uri, "uriBaseId" => "%SRCROOT%"}}
    region = if line, do: %{"region" => %{"startLine" => line}}, else: %{}
    %{"physicalLocation" => Map.merge(location, region)}
  end
end
