defmodule Cerbero.CLI.Format.JSON do
  @moduledoc "Stable, versioned, canonically-encoded JSON output."

  alias Cerbero.Finding
  alias Cerbero.Snapshot.Canonical

  @findings_version 1

  @spec render([Finding.t()], map()) :: String.t()
  def render(findings, summary) do
    Canonical.encode(%{
      "cerbero_findings_version" => @findings_version,
      "findings" =>
        findings
        |> Finding.stable_sort()
        |> Enum.map(fn f ->
          %{
            "check" => Atom.to_string(f.check),
            "engine" => f.engine && Atom.to_string(f.engine),
            "file" => f.file,
            "line" => f.line,
            "message" => f.message,
            # Structured provenance (direction/no_snapshot/skipped/lock):
            # Canonical sorts keys and stringifies atoms, so this stays
            # deterministic; an empty map encodes as {}.
            "metadata" => f.metadata,
            "relations" => f.relations,
            "severity" => Atom.to_string(f.severity)
          }
        end),
      "summary" => summary
    })
  end
end
