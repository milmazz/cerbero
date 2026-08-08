# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Offline safety checks for Ecto migrations, judged against a committed snapshot of production catalog metadata (PostgreSQL ≥ 13, CockroachDB ≥ v23.1). The claim is precise and must stay that way: cerbero judges *the statement, not the moment* — it never certifies migrations as safe and never estimates wall-clock durations. Exit codes: `0` clean, `1` unsafe at `--fail-on`, `2` misconfigured (operational problems are exit 2, never a silent pass).

## Commands

```sh
mix precommit          # CI-parity gate: format check, credo --strict, compile
                       # --warnings-as-errors, test, docs --warnings-as-errors.
                       # Run before every push; runs in MIX_ENV=test like CI.

mix test                                  # layers 0–2 (unit, rule, golden CLI)
mix test test/cerbero/severity_test.exs:42   # single test
UPDATE_GOLDEN=1 mix test                  # regenerate test/golden/* after an
                                          # intentional output change — diff first

docker compose -f docker-compose.test.yml up -d
mix test --include postgres --include integration   # layers 3–4: live PG 13/16
                                                    # + CockroachDB v25.1
```

`mix cerbero.check` deliberately does **not** start the app (offline); `mix cerbero.snapshot` does (needs Postgrex).

## Architecture

The whole tool is one pipeline, orchestrated by `Cerbero.CLI.Check` (mix tasks are thin shims):

1. **Parse** — `Migration.Parser` reads migration files as AST only (`Code.string_to_quoted`; user code is *never* executed). DSL calls become `Cerbero.Operation.*` structs; anything dynamic becomes `Op.Unknown`. Raw `execute` SQL goes through `SQL.Classifier`, an ordered regex ladder where **clause order is semantic** (e.g. `add_primary_key` must precede the greedy `ADD COLUMN`) and the honest fallback is `:unknown`.
2. **Load** — `Snapshot.load/2`: checksum → optional Ed25519 signature → format-version gate → strict allowlist decode (unknown fields rejected at every level). Any failure is exit 2. `Staleness` shrinks severity thresholds ×0.5 past 14 days and degrades all scale to unbounded past 90.
3. **Judge** — `Check.Runner` folds pending migrations through the 11 checks, threading a catalog overlay (`Catalog.apply_migration/2`) so migration N sees the world 1..N−1 created; within one migration, `Check.Helpers.fold_operations/3` threads per-op. Each rule derives `DDL.Effects` → `DDL.Locks` (a literal `(class, engine, version) → {lock, cost}` data table) and walks the shared judgment spine `Check.Judgment.judge/6` (born-silence → scale/traffic → `Severity.assess/6` → finding assembly with judged-lock metadata), parameterizing it with its own target selection and message text.
4. **Render** — `CLI.Format.{Human,JSON,SARIF}`; exit 1 if any finding meets `fail_on`.

`Check.SnapshotHealth` is *not* a regular check: it judges the snapshot itself, runs outside the Runner fold, and the CLI must route its findings through `Runner.apply_policies/3` so `severity_overrides`/`skip_checks` still apply — keep that wiring if you touch the health path.

## Invariants (violating these fails review — see CONTRIBUTING.md)

- **Never silent.** Unparseable, unclassifiable, or unmapped operations become findings (`Op.Unknown`, `:unknown` class, conservative AccessExclusive+rewrite default, `MetaFindings` warnings) — never a pass. Skips (`@cerbero_skip`, `skip_checks`) demote to `:info` with a reason; nothing silences. Regression net: `test/cerbero/check/never_silent_test.exs`.
- **Unknown scale is unbounded, never small.** Missing stats, stale snapshots, unstatted partitions all degrade toward "assume huge" (one unknown partition poisons the parent's sum).
- **Data, not conditionals.** Lock/cost facts live in `ddl/locks.ex` and `ddl/crdb.ex` and are *empirically verified* — layer 4 asserts each mapping against live `pg_locks` (strongest-lock), and one CRDB rejection claim was already falsified against a real node. Change the data, then run layer 4. Destructuring tripwires like `{:limited, _} = CRDB.judge(...)` are deliberate — don't "fix" them into case statements; comments at those sites record the evidence.
- **Privacy boundary.** Every SQL statement the exporter can run lives on one screen in `snapshot/exporter/queries.ex`. Snapshot fields are identifiers/enums/numbers/timestamps only — adding a field means touching both the strict-decode allowlists in `snapshot.ex` and `test/cerbero/privacy_test.exs`, deliberately.

## Testing conventions

- Rule tests use `Cerbero.Test.RuleCase.judge/4` + `SnapshotBuilder` (fixtures run through the *real* checksum + strict-decode path); `big_events_table/0` is the standard 412M-row fixture.
- CLI output is golden-tested byte-for-byte (`test/golden/`); understand a golden diff before regenerating.
- Tests that write scratch files use `@tag :tmp_dir` and the context's `tmp_dir` — never `System.tmp_dir!()`.
- `.credo.exs` carries two commented, deliberate deviations (complexity 12 with `sql/classifier.ex` excluded; nesting 3). Don't refactor code purely to satisfy a metric when a comment explains its shape.

## Other conventions

- Snapshot format v1 is the entire pre-release baseline (`precision` and `signature` are optional v1 fields); the version number only moves on a backwards-incompatible change after release.
- `.cerbero.exs` is `Code.eval_file`'d by design — repo-local trust, same as `mix.exs` (documented in SECURITY.md).
- Comments in this codebase record constraints and empirical evidence (falsified claims, PG/CRDB quirks, why a shape is deliberate). Preserve them when refactoring; they are load-bearing.
