# Contributing to cerbero

Thanks for your interest in improving cerbero. This document explains how the
project is laid out, how to run its test layers, and what a good pull request
looks like here.

## Ground rules

- **The claim is precise and must stay that way.** Cerbero detects a
  catalog-derivable class of unsafe migrations, judged at export-time scale.
  It never certifies migrations as safe and never estimates wall-clock
  durations. Contributions that would soften or overstate this claim —
  in code, messages, or docs — will be asked to reword.
- **The privacy boundary is load-bearing.** The snapshot may contain
  identifiers, type names, enumerated keywords, booleans, numbers, and
  timestamps — never expression text, never literals, never row data. Every
  SQL statement the exporter can run lives in
  `Cerbero.Snapshot.Exporter.Queries`; adding any free-text-capable snapshot
  field requires touching `test/cerbero/privacy_test.exs`, deliberately.
- **Never silent.** Operations cerbero cannot judge surface as
  `unclassified_sql` / `unknown_operation` / `unmapped_operation` warnings.
  Unknown scale is unbounded, never small. An ACCESS EXCLUSIVE-taking
  operation always produces at least an info note. New code paths must
  preserve these invariants (see `test/cerbero/check/never_silent_test.exs`).
- **User migration code is never executed.** Parsing is static AST analysis
  only.

## Development setup

Requirements: Elixir ≥ 1.18 (stdlib `JSON`), Docker (integration layers only).

```sh
mix deps.get
mix test                      # fast unit + golden suite, no database needed
```

The full matrix needs the test containers:

```sh
docker compose -f docker-compose.test.yml up -d   # pg13, pg16, crdb
mix test --include postgres --include integration
```

Integration tests skip *visibly* when a container is unreachable — a skipped
leg is reported, never silently passed.

Before pushing, all four gates must be clean:

```sh
mix test
mix format --check-formatted
mix compile --warnings-as-errors
mix docs   # zero warnings
```

## Project layout, briefly

- `lib/cerbero/snapshot*` — snapshot format: canonical encoder, checksum,
  strict decode, staleness, exporter + query allowlist.
- `lib/cerbero/migration/parser.ex`, `lib/cerbero/sql/classifier.ex` —
  static AST parsing and the raw-SQL keyword classifier.
- `lib/cerbero/ddl/` — the (operation, engine, version) → lock/cost data
  tables. These are **data**, empirically anchored by
  `test/integration/lock_verification_test.exs`; if you change an entry, the
  live `pg_locks` assertion must agree with you.
- `lib/cerbero/catalog.ex` — the in-memory model and the pending-migration
  overlay.
- `lib/cerbero/check/` — the rules. Each implements the `Cerbero.Check`
  behaviour; scale-gated rules use the migration-local catalog fold pattern
  (see `unsafe_index_creation.ex`) and silence born-this-deploy tables.
- `lib/cerbero/cli/` + `lib/mix/tasks/` — CLI orchestration and thin mix
  task shims.

## Tests

The suite is layered:

- **Layer 0/1** — pure unit and fixture-based rule tests
  (the helpers in `test/support/snapshot_builder.ex` and
  `test/support/rule_case.ex`).
- **Layer 2** — golden CLI output, byte-compared. Regenerate with
  `UPDATE_GOLDEN=1 mix test`, then *read the diff* before committing it.
- **Layer 3** (`@tag :postgres`) — exporter against live PostgreSQL.
- **Layer 4** (`@tag :integration`) — the empirical lock-verification suite
  and the CockroachDB differential.

Write the failing test first. A rule change without a fixture pair
(safe/unsafe) exercising it is incomplete. If your change affects what the
checker reports, extend `never_silent_test.exs`'s class coverage rather than
narrowing it.

## Pull requests

- Keep commits focused; the project uses plain imperative commit subjects
  (`feat:`, `fix:`, `test:`, `docs:`, `chore:` prefixes are welcome but not
  enforced).
- Update `CHANGELOG.md` under the unreleased heading for user-visible
  changes.
- New checks: implement the `Cerbero.Check` behaviour, register before
  `MetaFindings` in `Cerbero.Check.Runner.default_checks/0`, and document
  the rule in the README's comparison table only if the claim is true.
- Engine-conditional behavior (PostgreSQL vs CockroachDB) must be verified
  against the live containers, not assumed from documentation — that is the
  lesson layer 4 exists to enforce.

## Questions

Open a GitHub issue at <https://github.com/milmazz/cerbero/issues>. For
security-sensitive reports, see [SECURITY.md](SECURITY.md) — please do not
open public issues for those.
