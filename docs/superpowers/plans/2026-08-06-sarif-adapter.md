# SARIF Output Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `--format sarif` to `mix cerbero.check`, emitting SARIF 2.1.0 so GitHub code scanning can annotate PRs with per-`file:line` findings.

**Architecture:** A new pure formatter module `Cerbero.CLI.Format.SARIF` sits next to the existing `Format.Human` and `Format.JSON`, consuming the same `[Cerbero.Finding.t()]` + summary map and encoding through the project's canonical JSON encoder for byte-stable output. `Cerbero.CLI.Check` threads the snapshot path through so global (file-less) findings can be anchored to the committed snapshot artifact.

**Tech Stack:** Elixir ~> 1.18 (built-in `JSON` module), ExUnit, golden-file tests.

**Spec:** `docs/superpowers/specs/2026-08-06-sarif-adapter-design.md`

## Global Constraints

- All JSON output goes through `Cerbero.Snapshot.Canonical.encode/1` (sorted keys, 2-space indent, trailing newline) — never `JSON.encode!` directly for document output.
- Severity → SARIF level mapping is exactly: `:error` → `"error"`, `:warning` → `"warning"`, `:info` → `"note"`. All findings are emitted, including infos.
- Global findings (`file` nil) anchor to the snapshot path at `startLine` 1; with no snapshot path either, the result has no `locations` key.
- Exit-code semantics are unchanged; `--format sarif` affects output only.
- Run `mix format` before every commit; the project has zero-warning expectations (`mix test` must be clean).
- Golden files regenerate with `UPDATE_GOLDEN=1 mix test test/cerbero/cli/check_test.exs` — always inspect the regenerated file before committing it.
- Every commit message ends with:

  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_0139RYoE7Vz9X93aGgWKBhvR
  ```

---

### Task 1: `Cerbero.CLI.Format.SARIF` module

**Files:**
- Create: `lib/cerbero/cli/format/sarif.ex`
- Test: `test/cerbero/cli/format/sarif_test.exs` (new file; the `format/` test directory doesn't exist yet)

**Interfaces:**
- Consumes: `Cerbero.Finding` struct (`check :: atom`, `severity :: :error | :warning | :info`, `message :: String.t()`, `file :: String.t() | nil`, `line :: integer() | nil`, `relations :: [String.t()]`, `engine :: atom | nil`); `Cerbero.Snapshot.Canonical.encode/1`.
- Produces: `Cerbero.CLI.Format.SARIF.render(findings :: [Finding.t()], summary :: map(), snapshot_path :: String.t() | nil) :: String.t()` — Task 2 calls exactly this.

- [ ] **Step 1: Write the failing tests**

Create `test/cerbero/cli/format/sarif_test.exs`:

```elixir
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

    assert get_in(first, ["locations", Access.at(0), "physicalLocation", "artifactLocation", "uri"]) ==
             "a.exs"

    assert get_in(second, ["locations", Access.at(0), "physicalLocation", "artifactLocation", "uri"]) ==
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/cerbero/cli/format/sarif_test.exs`
Expected: FAIL — `Cerbero.CLI.Format.SARIF` is undefined (compile error or UndefinedFunctionError).

- [ ] **Step 3: Write the implementation**

Create `lib/cerbero/cli/format/sarif.ex`:

```elixir
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

  # One line per check id; unknown (third-party) ids fall back to the id.
  @rule_descriptions %{
    "column_default_rewrite" =>
      "Adding a column with a default that forces a full-table rewrite under an exclusive lock",
    "column_type_change" =>
      "Column type change that rewrites the table or rebuilds indexes at production scale",
    "concurrent_index_requires_attributes" =>
      "concurrently: true requires @disable_ddl_transaction and @disable_migration_lock",
    "crdb_transactional_ddl" =>
      "DDL that CockroachDB rejects or restricts inside a transaction",
    "dml_in_migration" => "Data-modifying statement inside a schema migration",
    "fk_missing_index" => "Foreign key whose referencing column has no covering index",
    "fk_validation_scan" =>
      "ADD FOREIGN KEY scans the referencing table while blocking writes on the referenced table",
    "meta_findings" => "Operation cerbero cannot fully judge; warned, never silenced",
    "not_null_on_populated_table" =>
      "SET NOT NULL scans a populated table under an exclusive lock unless a validated CHECK proves it",
    "raw_ddl_safety" =>
      "Raw DDL judged by lock mode and cost class against production scale",
    "snapshot_health" =>
      "The snapshot itself is degraded: stale, divergent, invalid indexes, or standby stats",
    "unclassified_sql" => "Raw SQL the classifier cannot classify; judged conservatively",
    "unknown_operation" => "Migration operation the parser does not recognize",
    "unmapped_operation" => "Classified SQL with no lock-table entry; judged conservatively",
    "unsafe_index_creation" =>
      "Non-concurrent index creation takes a SHARE lock that blocks writes for a full-table scan"
  }

  @spec render([Finding.t()], map(), String.t() | nil) :: String.t()
  def render(findings, summary, snapshot_path) do
    findings =
      Enum.sort_by(findings, &{&1.file || "", &1.line || 0, Atom.to_string(&1.check)})

    rule_ids =
      findings |> Enum.map(&Atom.to_string(&1.check)) |> Enum.uniq() |> Enum.sort()

    rule_index = rule_ids |> Enum.with_index() |> Map.new()

    %{
      "$schema" => @schema,
      "version" => "2.1.0",
      "runs" => [
        %{
          "tool" => %{"driver" => driver(rule_ids)},
          "results" => Enum.map(findings, &result(&1, rule_index, snapshot_path)),
          "properties" => %{"summary" => summary}
        }
      ]
    }
    |> Canonical.encode()
  end

  defp driver(rule_ids) do
    %{
      "informationUri" => @information_uri,
      "name" => "cerbero",
      "rules" => Enum.map(rule_ids, &rule/1),
      "semanticVersion" => version(),
      "version" => version()
    }
  end

  defp rule(id) do
    %{
      "id" => id,
      "name" => id,
      "shortDescription" => %{"text" => Map.get(@rule_descriptions, id, id)}
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

  defp properties(%Finding{relations: relations, engine: nil}),
    do: %{"relations" => relations}

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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/cerbero/cli/format/sarif_test.exs`
Expected: PASS, all tests.

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/cerbero/cli/format/sarif.ex test/cerbero/cli/format/sarif_test.exs
git commit -m "feat: SARIF 2.1.0 format module (roadmap item 6)"
```

(Append the Global Constraints commit footer.)

---

### Task 2: Wire `--format sarif` into the CLI, with golden test

**Files:**
- Modify: `lib/cerbero/cli/check.ex` (the `render/5` helper and its two call sites, lines ~130 and ~160)
- Modify: `test/cerbero/cli/check_test.exs` (add one test)
- Create: `test/golden/check_sarif.json` (generated, then inspected)

**Interfaces:**
- Consumes: `Cerbero.CLI.Format.SARIF.render(findings, summary, snapshot_path)` from Task 1.
- Produces: `mix cerbero.check --format sarif` end to end; golden file pins the bytes.

- [ ] **Step 1: Write the failing CLI test**

Add to `test/cerbero/cli/check_test.exs`, after the `"json output matches golden and is canonically stable"` test:

```elixir
  test "sarif output matches golden and anchors findings for code scanning" do
    {code, output} =
      run([
        "--snapshot",
        @snapshot,
        "--migrations",
        @migrations,
        "--config",
        "nonexistent",
        "--format",
        "sarif"
      ])

    assert code == 1
    golden("check_sarif.json", output)

    doc = JSON.decode!(output)
    assert doc["version"] == "2.1.0"

    [sarif_run] = doc["runs"]
    assert sarif_run["tool"]["driver"]["name"] == "cerbero"
    assert [result | _] = sarif_run["results"]
    assert result["ruleId"] == "unsafe_index_creation"
    assert result["level"] == "error"

    [%{"physicalLocation" => loc}] = result["locations"]
    assert loc["artifactLocation"]["uri"] =~ "20260801000000_add_events_payload_index.exs"
    assert loc["region"] == %{"startLine" => 5}
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cerbero/cli/check_test.exs`
Expected: the new test FAILS with exit code 2 and output `invalid --format: sarif` (the `assert code == 1` fails). All existing tests still pass.

- [ ] **Step 3: Wire the format into `Cerbero.CLI.Check`**

In `lib/cerbero/cli/check.ex`, make three edits.

1. In `with_snapshot/5`, the `render` call currently reads:

```elixir
      render(parsed, findings, summary_line, summary, fail_on)
```

Replace with:

```elixir
      render(parsed, findings, summary_line, summary, fail_on, parsed[:snapshot] || config.snapshot_path)
```

2. In `structural/4`, the `render` call currently reads:

```elixir
    render(parsed, findings, summary_line, summary, fail_on)
```

Replace with:

```elixir
    render(parsed, findings, summary_line, summary, fail_on, nil)
```

3. Replace the whole `render/5` helper:

```elixir
  defp render(parsed, findings, summary_line, summary, fail_on) do
    output =
      case parsed[:format] || "human" do
        "human" -> Format.Human.render(findings, summary_line, parsed[:verbose] || false)
        "json" -> Format.JSON.render(findings, summary)
        other -> {:error, "invalid --format: #{other}"}
      end

    with out when is_binary(out) <- output do
      exit_code = if Enum.any?(findings, &Finding.at_least?(&1.severity, fail_on)), do: 1, else: 0
      {:ok, out, exit_code}
    end
  end
```

with:

```elixir
  defp render(parsed, findings, summary_line, summary, fail_on, snapshot_path) do
    output =
      case parsed[:format] || "human" do
        "human" -> Format.Human.render(findings, summary_line, parsed[:verbose] || false)
        "json" -> Format.JSON.render(findings, summary)
        "sarif" -> Format.SARIF.render(findings, summary, snapshot_path)
        other -> {:error, "invalid --format: #{other}"}
      end

    with out when is_binary(out) <- output do
      exit_code = if Enum.any?(findings, &Finding.at_least?(&1.severity, fail_on)), do: 1, else: 0
      {:ok, out, exit_code}
    end
  end
```

- [ ] **Step 4: Generate the golden file and inspect it**

Run: `UPDATE_GOLDEN=1 mix test test/cerbero/cli/check_test.exs`
Then read `test/golden/check_sarif.json` and verify by eye:
- `$schema` points at sarif-schema-2.1.0; `version` is `"2.1.0"`.
- One result: `ruleId` `"unsafe_index_creation"`, `level` `"error"`, location uri `test/fixtures/migrations/unsafe/20260801000000_add_events_payload_index.exs` with `startLine` 5, `uriBaseId` `"%SRCROOT%"`.
- `runs[0].properties.summary` matches the JSON golden's `summary` object (same counts and snapshot block).
- Keys are sorted lexicographically at every level; the file ends with a newline.

- [ ] **Step 5: Run the full CLI test file without UPDATE_GOLDEN**

Run: `mix test test/cerbero/cli/check_test.exs`
Expected: PASS, including byte-for-byte golden match.

- [ ] **Step 6: Format and commit**

```bash
mix format
git add lib/cerbero/cli/check.ex test/cerbero/cli/check_test.exs test/golden/check_sarif.json
git commit -m "feat: --format sarif on mix cerbero.check"
```

(Append the Global Constraints commit footer.)

---

### Task 3: Documentation touch-ups and full-suite verification

**Files:**
- Modify: `lib/cerbero/cli/format/json.ex:2` (moduledoc says "SARIF adapter deferred" — no longer true)
- Modify: `CHANGELOG.md` (Added section of v0.1.0 unreleased)

**Interfaces:**
- Consumes: nothing new.
- Produces: accurate docs; green full suite.

- [ ] **Step 1: Fix the stale JSON moduledoc**

In `lib/cerbero/cli/format/json.ex`, replace:

```elixir
  @moduledoc "Stable, versioned, canonically-encoded JSON output (SARIF adapter deferred)."
```

with:

```elixir
  @moduledoc "Stable, versioned, canonically-encoded JSON output."
```

- [ ] **Step 2: Add the CHANGELOG entry**

In `CHANGELOG.md`, under `## v0.1.0 (unreleased)` → `### Added`, append this bullet at the end of the list:

```markdown
- `--format sarif` on `mix cerbero.check` — SARIF 2.1.0 output for GitHub
  code-scanning annotations. Findings map `error`/`warning`/`note` from their
  severities; global snapshot-health findings anchor to the committed snapshot
  file so they still surface in PR review.
```

- [ ] **Step 3: Run the full test suite**

Run: `mix test`
Expected: PASS, zero failures, no new warnings.

- [ ] **Step 4: Format and commit**

```bash
mix format
git add lib/cerbero/cli/format/json.ex CHANGELOG.md
git commit -m "docs: record SARIF output in changelog, drop deferred note"
```

(Append the Global Constraints commit footer.)
