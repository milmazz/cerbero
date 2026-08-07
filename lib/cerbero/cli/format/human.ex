defmodule Cerbero.CLI.Format.Human do
  @moduledoc """
  Severity-first human output: findings are grouped into an errors section,
  then warnings, then (only with `--verbose`) informational notes, each
  section headed by a count so the reader knows what to fix first. Color is
  applied via `IO.ANSI` and disabled automatically when output is not a
  terminal or `NO_COLOR` is set, so piped/CI logs stay plain and the golden
  tests stay stable.
  """

  alias Cerbero.Finding

  # Highest severity first — the whole point of the reorder.
  @severities [:error, :warning, :info]

  @glyph %{error: "✖", warning: "⚠", info: "•"}
  @color %{error: :red, warning: :yellow, info: :cyan}
  @call_to_action %{error: " — fix before deploy", warning: "", info: ""}

  @spec render([Finding.t()], String.t(), boolean()) :: String.t()
  @spec render([Finding.t()], String.t(), boolean(), keyword()) :: String.t()
  def render(findings, summary_line, verbose, opts \\ []) do
    color? = Keyword.get(opts, :color, color_default?())

    {infos, loud} = Enum.split_with(findings, &(&1.severity == :info))
    shown = if verbose, do: findings, else: loud

    pad = Enum.reduce(shown, 0, &max(&2, String.length(to_string(&1.check))))

    sections =
      @severities
      |> Enum.map(fn severity -> {severity, Enum.filter(shown, &(&1.severity == severity))} end)
      |> Enum.reject(fn {_severity, group} -> group == [] end)
      |> Enum.map(fn {severity, group} -> section(severity, group, pad) end)

    blocks = [["cerbero: ", summary_line]] ++ sections ++ [tally(loud, infos, findings, verbose)]

    [Enum.intersperse(blocks, "\n\n"), "\n"]
    |> IO.ANSI.format(color?)
    |> IO.iodata_to_binary()
  end

  defp section(severity, group, pad) do
    count = length(group)

    head = [
      @color[severity],
      :bright,
      @glyph[severity],
      " ",
      Integer.to_string(count),
      " ",
      pluralize(severity, count),
      @call_to_action[severity],
      :reset
    ]

    rows =
      group
      |> Enum.sort_by(&{&1.file || "", &1.line || 0})
      |> Enum.map(&row(&1, pad))
      |> Enum.intersperse("\n")

    [head, "\n", rows]
  end

  defp row(finding, pad) do
    check = String.pad_trailing(to_string(finding.check), pad)

    [
      "  ",
      :bright,
      check,
      :reset,
      "  ",
      :faint,
      location(finding),
      :reset,
      "\n",
      "    ",
      finding.message
    ]
  end

  # A global finding has no source location; show it once, not doubled as a
  # header and a parenthesized suffix the way the old grouped layout did.
  defp location(%{file: nil}), do: "(global)"
  defp location(%{file: file, line: nil}), do: file
  defp location(%{file: file, line: line}), do: "#{file}:#{line}"

  defp tally(loud, infos, findings, verbose) do
    counts = Enum.frequencies_by(findings, & &1.severity)

    base =
      "#{length(loud)} finding(s) " <>
        "(#{Map.get(counts, :error, 0)} error, #{Map.get(counts, :warning, 0)} warning)"

    if not verbose and infos != [] do
      base <> "; #{length(infos)} informational note(s); --verbose to show"
    else
      base
    end
  end

  defp pluralize(:error, 1), do: "error"
  defp pluralize(:error, _), do: "errors"
  defp pluralize(:warning, 1), do: "warning"
  defp pluralize(:warning, _), do: "warnings"
  defp pluralize(:info, 1), do: "informational note"
  defp pluralize(:info, _), do: "informational notes"

  defp color_default?, do: IO.ANSI.enabled?() and System.get_env("NO_COLOR") in [nil, ""]
end
