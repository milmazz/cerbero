defmodule Cerbero.CLI.Format.Human do
  @moduledoc "Grouped-per-migration human output; info notes collapsed unless verbose."

  alias Cerbero.Finding

  @spec render([Finding.t()], String.t(), boolean()) :: String.t()
  def render(findings, summary_line, verbose) do
    {infos, loud} = Enum.split_with(findings, &(&1.severity == :info))
    shown = if verbose, do: findings, else: loud

    groups =
      shown
      |> Enum.sort_by(&{&1.file || "", &1.line || 0})
      |> Enum.group_by(&(&1.file || "(global)"))
      |> Enum.sort()

    body =
      Enum.map_join(groups, "\n", fn {file, file_findings} ->
        lines =
          Enum.map_join(file_findings, "\n", fn f ->
            loc = if f.line, do: "#{file}:#{f.line}", else: file
            "  [#{f.severity}] #{f.check}: #{f.message} (#{loc})"
          end)

        file <> "\n" <> lines
      end)

    counts = Enum.frequencies_by(findings, & &1.severity)

    tally =
      "#{length(loud)} finding(s) " <>
        "(#{Map.get(counts, :error, 0)} error, #{Map.get(counts, :warning, 0)} warning)" <>
        if not verbose and infos != [] do
          "; #{length(infos)} informational note(s); --verbose to show"
        else
          ""
        end

    Enum.join(Enum.reject(["cerbero: " <> summary_line, body, tally], &(&1 == "")), "\n\n") <>
      "\n"
  end
end
