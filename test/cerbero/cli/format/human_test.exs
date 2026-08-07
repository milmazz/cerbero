defmodule Cerbero.CLI.Format.HumanTest do
  use ExUnit.Case, async: true

  alias Cerbero.CLI.Format.Human
  alias Cerbero.Finding

  defp finding(severity, check, message, file \\ nil, line \\ nil) do
    %Finding{severity: severity, check: check, message: message, file: file, line: line}
  end

  defp render(findings, opts \\ [verbose: false, color: false]) do
    Human.render(findings, "summary line", Keyword.get(opts, :verbose, false),
      color: Keyword.get(opts, :color, false)
    )
  end

  test "errors are listed before warnings regardless of file/line order" do
    findings = [
      finding(:warning, :fk_missing_index, "warn msg", "b.exs", 1),
      finding(:error, :int_to_bigint, "error msg", "a.exs", 9)
    ]

    output = render(findings)

    assert output =~ "✖ 1 error — fix before deploy"
    assert output =~ "⚠ 1 warning"
    # error section precedes the warning section
    assert :binary.match(output, "✖ 1 error") < :binary.match(output, "⚠ 1 warning")
  end

  test "a global finding renders its location once, not doubled" do
    output = render([finding(:warning, :snapshot_health, "invalid index")])

    assert output =~ "(global)"
    refute output =~ "((global))"
  end

  test "informational notes are collapsed unless --verbose" do
    findings = [finding(:info, :note_check, "just so you know")]

    collapsed = render(findings, verbose: false, color: false)
    assert collapsed =~ "1 informational note(s); --verbose to show"
    refute collapsed =~ "• 1 informational note"

    verbose = render(findings, verbose: true, color: false)
    assert verbose =~ "• 1 informational note"
  end

  test "color: false emits no ANSI escapes; color: true does" do
    findings = [finding(:error, :int_to_bigint, "boom", "a.exs", 1)]

    refute render(findings, color: false) =~ "\e["
    assert render(findings, color: true) =~ "\e["
  end

  test "no findings still renders a clean pass" do
    output = render([])

    assert output =~ "cerbero: summary line"
    assert output =~ "0 finding(s) (0 error, 0 warning)"
  end
end
