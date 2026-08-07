# SARIF Output Adapter — Design

**Date:** 2026-08-06
**Roadmap:** issue #1, Tier 2, item 6
**Status:** approved

## Purpose

Emit findings as SARIF 2.1.0 so GitHub code scanning can annotate PRs with
per-`file:line` findings. Deliberately a mechanical adapter over the stable
findings shape — no new judgment, no new configuration beyond the format
switch.

## CLI surface

`mix cerbero.check --format sarif` — a third value for the existing
`--format` switch, writing the SARIF document to stdout exactly like the
`human` and `json` formats. CI redirects stdout to a file for upload
(`github/codeql-action/upload-sarif`). No `--output` flag, no separate mix
task. Exit-code semantics are unchanged; SARIF consumers upload the file
regardless of exit code.

## Architecture

New module `Cerbero.CLI.Format.SARIF`, sitting next to `Format.Human` and
`Format.JSON`:

```
render(findings :: [Finding.t()], summary :: map(), snapshot_path :: String.t() | nil) :: String.t()
```

- Encoded with `Cerbero.Snapshot.Canonical.encode/1` — sorted keys, 2-space
  indent, trailing newline — for byte-stable output and golden-testability.
- `Cerbero.CLI.Check.render/5` gains a `"sarif"` branch. The snapshot path
  (`parsed[:snapshot] || config.snapshot_path`; `nil` in `--no-snapshot`
  mode) is threaded to `render` so global findings can be anchored.

## Document shape

One `run` in a SARIF 2.1.0 document (`$schema` pointing at the 2.1.0
schema, `version: "2.1.0"`).

`tool.driver`:

- `name`: `"cerbero"`
- `version` / `semanticVersion`: from `Application.spec(:cerbero, :vsn)`
- `informationUri`: the project repository URL
- `rules`: one entry per **distinct `check` id appearing in the findings**,
  sorted by id. Each entry: `id`, `name` (the id), `shortDescription.text`
  from a static map inside the SARIF module; unknown ids (third-party
  checks, roadmap item 7) fall back to the id itself. The static map covers
  every internal check id (`unsafe_index_creation`, `column_type_change`,
  `not_null_on_populated_table`, `column_default_rewrite`,
  `fk_missing_index`, `fk_validation_scan`, `dml_in_migration`,
  `concurrent_index_requires_attributes`, `crdb_transactional_ddl`,
  `raw_ddl_safety`, `snapshot_health`, `meta_findings`, plus the meta
  finding ids `unclassified_sql`, `unknown_operation`,
  `unmapped_operation`).

`results`, sorted by `{file, line, check}` (same order as `Format.JSON`):

- `ruleId`: the check id; `ruleIndex`: index into the rules array
- `level`: `:error` → `"error"`, `:warning` → `"warning"`,
  `:info` → `"note"`. **All** findings are emitted, including infos,
  matching `Format.JSON`.
- `message.text`: the finding message verbatim
- `locations`: see below
- `properties`: `relations` (always, possibly empty list) and `engine`
  (when non-nil) — carried, not invented into SARIF semantics

Run-level `properties`: the existing summary map (error/warning/info counts
and snapshot provenance), so SARIF consumers see the same provenance the
JSON format exposes.

## Locations

- Finding with `file`: `physicalLocation.artifactLocation.uri` = the file
  path as stored on the finding (relative), `uriBaseId: "%SRCROOT%"`;
  `region.startLine` = `line`, omitted when `line` is nil (SARIF regions
  require a positive startLine).
- Global finding (`file` nil — snapshot_health): anchored to the snapshot
  path at `startLine: 1`. That file is committed and is what the finding
  is about.
- Defensive: no `file` and no snapshot path → result emitted with no
  `locations` (valid SARIF; GitHub won't annotate it). In practice
  `--no-snapshot` mode produces no global findings.

## Error handling

Nothing new. Rendering is pure over already-validated findings; invalid
`--format` values already exit 2 via the existing branch.

## Testing

- Golden file `test/golden/check_sarif.json` through the same CLI test
  path as the existing human/json goldens (covers a file-anchored error
  result end to end).
- Unit tests for `Format.SARIF`: info → `note` mapping, global finding →
  snapshot anchor, nil line omits `region`, no-snapshot mode omits
  `locations`, rules array deduplication/sorting/fallback description,
  engine/relations in properties.
- One-time manual validation of the golden against the SARIF validator /
  a GitHub upload; not part of CI.

## Out of scope

- `partialFingerprints` (GitHub computes its own)
- Markdown rule help / helpUris (docs-sync maintenance burden, deferred)
- `--output` file flag
- Any change to finding content, severity, or exit codes
