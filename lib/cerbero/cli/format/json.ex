defmodule Cerbero.CLI.Format.JSON do
  @moduledoc "Stable, versioned, canonically-encoded JSON output (SARIF adapter deferred)."

  alias Cerbero.Finding
  alias Cerbero.Snapshot.Canonical

  @findings_version 1

  @spec render([Finding.t()], map()) :: String.t()
  def render(findings, summary) do
    %{
      "cerbero_findings_version" => @findings_version,
      "findings" =>
        findings
        |> Enum.sort_by(&{&1.file || "", &1.line || 0, Atom.to_string(&1.check)})
        |> Enum.map(fn f ->
          %{
            "check" => Atom.to_string(f.check),
            "engine" => f.engine && Atom.to_string(f.engine),
            "file" => f.file,
            "line" => f.line,
            "message" => f.message,
            "relations" => f.relations,
            "severity" => Atom.to_string(f.severity)
          }
        end),
      "summary" => summary
    }
    |> Canonical.encode()
  end
end
