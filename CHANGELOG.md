# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.1.0 (unreleased)

Initial release: cerbero detects a specific catalog-derivable class of unsafe
Ecto migrations, judged at export-time scale, for PostgreSQL and CockroachDB.
It does not certify migrations as safe; it judges the statement, not the moment.

### Added

- `mix cerbero.snapshot` — exports a privacy-bounded snapshot of database
  catalog metadata (schema shapes, row/byte estimates, traffic counters,
  index/constraint validity) as a canonical, checksummed, human-diffable
  JSON artifact. Includes a DBA-mediated path (`--emit-sql` / `--from-file`)
  so the exporter's allowlisted queries can be reviewed and run with a DBA's
  own credentials.
- `mix cerbero.check` — judges pending migrations against the committed
  snapshot offline (no database reachable from CI), with exit codes
  `0`/`1`/`2`, human and JSON output, golden-tested formatting, and a
  no-snapshot structural mode (`--no-snapshot`) as a zero-friction trial path.
- Ten checks: non-concurrent index creation (partition-aware, with the
  per-partition recipe), `SET NOT NULL` two-step awareness (recognizes its own
  recommended `CHECK ... NOT VALID` + `VALIDATE CONSTRAINT` pattern, including
  in raw SQL), volatile-default and `GENERATED ... STORED` rewrites, catalog-aware
  column type changes (binary-coercible pairs stay quiet; index rebuilds are
  named), foreign-key validation scans (both tables' scale; the referenced
  table's blocked writes are called out), missing FK indexes (covering both
  `alter table` adds and `references(...)` declared inside the create block;
  primary-key columns count as covered), CockroachDB
  transactional-DDL restrictions, snapshot health (staleness, invalid indexes,
  history divergence, absent tables), unbatched DML at scale, and
  `CREATE INDEX CONCURRENTLY` attribute requirements (both the DSL
  `concurrently: true` form and raw-SQL CIC — including the raw
  per-partition CIC that rule 1's own partitioned-parent remediation
  recommends).
- A raw-DDL safety net: classified raw SQL that no named rule owns is still
  judged by lock mode and cost — an ACCESS EXCLUSIVE-taking operation is
  never silent, and `TRUNCATE` carries an error-severity floor.
- Classifier patterns for the remaining raw DDL: `RENAME` (table, column,
  constraint), `ATTACH/DETACH PARTITION` (the attach validation scan is
  charged to the attached partition; `DETACH ... CONCURRENTLY` is
  recognized), `SET LOGGED`/`SET UNLOGGED` (full rewrite under ACCESS
  EXCLUSIVE), and `SET/DROP DEFAULT` — all judged by the raw-DDL safety
  net instead of surfacing as generic `unclassified_sql` warnings.
- Severity that tracks reality: row/byte tiers, traffic-aware lock-queue
  gating, staleness headroom (thresholds shrink as the snapshot ages), and
  degradation to unknown-is-unbounded past the configured age. Unknown scale
  is never treated as small.
- Static AST migration parsing (user migration code is never executed) with
  an explicit `Unknown` escape route, and a keyword SQL classifier with an
  `unclassified_sql` escape route — both reachable by `--fail-on`.
- A lock/cost table verified empirically: the integration suite executes
  representative DDL against live PostgreSQL 13 and 16 and asserts the
  acquired `pg_locks` modes, plus a CockroachDB differential against v25.1.
- Per-migration escape hatch (`@cerbero_skip`, reason required, findings
  still shown) and configuration via `.cerbero.exs` (thresholds, headroom,
  staleness ages, severity overrides, `strict_concurrent_index`,
  `lock_timeout_attested`, schemas, paths).
- Third-party check registration: the `extra_checks` config key registers
  modules implementing the public `Cerbero.Check` behaviour into the
  runner (validated at config load; additive only — built-ins are never
  displaced, and a built-in listed there is not run twice). Registered
  checks get `skip_checks`, `severity_overrides`, and `@cerbero_skip`
  handling like any built-in.
- Aged-pending grace window tied to deploy cadence: the `deploy_cadence`
  config key (days, default 1) keeps the snapshot-health heuristic from
  flagging every pending migration merely older than a nightly-refreshed
  snapshot; only migrations predating it by more than one deploy cycle warn.
- Opt-in `precision: :order_of_magnitude` export mode (config or
  `mix cerbero.snapshot --precision`): buckets every exported count and byte
  to its power-of-ten floor so committed snapshots do not reveal exact
  business metrics; the default row tiers are powers of ten, so verdicts
  survive. Adds the optional `precision` field to the snapshot (part of the
  format v1 baseline; absent means exact) and the check summary line notes
  the reduced precision.
- `--format sarif` on `mix cerbero.check` — SARIF 2.1.0 output for GitHub
  code-scanning annotations. Findings map `error`/`warning`/`note` from their
  severities; global snapshot-health findings anchor to the committed snapshot
  file so they still surface in PR review.
- Cryptographic snapshot signing: `mix cerbero.snapshot
  --gen-signing-key` mints an Ed25519 keypair, `--sign-key` signs the export
  (signature over the checksum, which covers the canonical content), and
  `snapshot_verify_keys` in `.cerbero.exs` pins the trusted public keys —
  once set, an unsigned, tampered-and-restamped, or foreign-key-signed
  snapshot refuses to load. Unsigned snapshots without pinned keys behave
  exactly as before. The optional `signature` field is part of the snapshot
  format v1 baseline.
- `mix cerbero.check --down` judges rollback bodies: `def down` operations and
  the down leg of two-arg `execute` are parsed into their own operation list
  and judged against the catalog as the pending ups leave it (the state a
  rollback starts from), with findings labeled `[down]`. Off by default —
  deploy-direction output is unchanged without the flag.
- Multi-repo configuration for umbrella apps: a `repos` config key defines one
  `{name, migrations_paths, snapshot_path}` entry per Ecto repo. With no flag,
  `mix cerbero.check` runs every repo and merges findings into one document
  (worst exit code wins; each repo's global findings anchor to its own
  snapshot artifact); `--repo NAME` runs one. All other settings stay global,
  and explicit `--migrations`/`--snapshot` still bypass the repo table.
- CRDB support for the DBA path: `mix cerbero.snapshot --emit-sql --engine
  cockroachdb` emits a CRDB-branched script (CRDB speaks pgwire and supports
  the same `COPY (SELECT row_to_json(...)) TO STDOUT` mechanism, verified on
  v25.1), and `--from-file` detects the engine from the file's own sections —
  including the crdb row-count and stats-timestamp sections — with no
  out-of-band flag.
- Layer-4 lock verification now asserts the mapped lock is the *strongest*
  mode held on the target relation, not merely among the held modes, so an
  over-locking regression can no longer hide behind a weaker mapped entry.
  Verified green against live PG 13 and PG 16.
- CRDB analyze-timestamp equivalent: the exporter now fills
  `last_analyze`/`last_autoanalyze` for CockroachDB tables from statistics
  creation times (`system.table_statistics`, what `SHOW STATISTICS` reads) —
  manual `CREATE STATISTICS` maps to analyze, automatic `__auto__`
  collections to autoanalyze — so CRDB findings carry stats dates like PG
  findings do. Degrades to honest `nil` when `system.*` is not readable.
- Per-table stats-age `snapshot_health` finding: an error-tier table targeted
  by the pending set whose statistics were already older than
  `stale_warn_days` at export (or never analyzed) now gets an explicit
  low-confidence warning, instead of only an old date inside other rules'
  messages. Standby snapshots keep their single standby warning.
- Raw-SQL `ADD COLUMN ... DEFAULT` volatility detection for rule 3: a default
  opening with a function call or parenthesized expression (`now()`,
  `random()`, `gen_random_uuid()`, `nextval(...)`) now classifies as
  `add_column_volatile_default` and gets the rewrite warning, mirroring the
  exporter's literal-vs-expression honesty line; literals and casts stay
  metadata-only.
- CRDB type changes now name the real remaining rejection: when the table has
  a separate `GENERATED ... STORED` column, the warning cites the
  dependent-generated-column mechanism (SQLSTATE 2BP01) and its drop/re-add
  remediation instead of only the generic transaction restriction.
- `mix cerbero.gen.config` — writes a `.cerbero.exs` populated with the
  built-in defaults, every setting visible and commented; deleting a line
  falls back to the same default. Refuses to overwrite without `--force`.

### Fixed

- Snapshot mode with `start_after` no longer silently drops migration files
  whose name carries no timestamp version. Pending selection existed twice —
  the no-snapshot path guarded `version != nil` while the snapshot path's
  `version <= start_after` term-compared `nil` below any string, so the same
  unversioned file was judged in one mode and dropped in the other. Both
  modes now share one policy (`Runner.split_pending/3`): a nil-version
  migration is always pending, always judged.
- Non-concurrent index builds on a CockroachDB table with unknown scale now
  warn instead of passing silently. Rule 1's CRDB cost branch pattern-matched
  on `{:rows, ...}` and its `else` swallowed `:unknown` — a direct violation
  of the "unknown scale is unbounded, never small" doctrine (rules 2 and 3
  already warned on the same input). The CRDB online-schema-change cost tier
  now lives in `Severity.assess/6` — the module that owns judgment policy —
  as an explicit `:online_schema_change` clause shared by rules 1–3, and
  `Check.Helpers.crdb_cost_severity/3` is gone.
  (`Finding.metadata.lock`, declared by each rule) instead of matching finding
  message text for `"lock_timeout"` / `"ACCESS EXCLUSIVE"`. The string match
  missed `fk_validation_scan` findings entirely — their SHARE ROW EXCLUSIVE
  messages contained neither string — so attested teams never saw the
  annotation there, and any wording edit could silently flip attestation.
- `severity_overrides` and `skip_checks` now reach `snapshot_health` findings.
  Those findings are produced outside the per-migration check runner (they
  judge the snapshot, not a migration), so the documented
  `severity_overrides: %{snapshot_health: :error}` and
  `skip_checks: [:snapshot_health]` were silently ignored for them.
  Per-migration `@cerbero_skip` still does not apply to global findings —
  they belong to no single migration.
- `mix cerbero.snapshot` now writes to `config.snapshot_path` when `--out` is
  omitted, instead of a hardcoded `priv/repo/cerbero_snapshot.json`. The two
  tasks previously disagreed on the path whenever `snapshot_path` was
  customized: the exporter wrote one place and `mix cerbero.check` read
  another (silently judging a stale or absent artifact), and on layouts with
  no `priv/repo/` at the root — umbrella apps — the write crashed outright.
  Explicit `--out` still overrides.

### Known limitations

- `down` bodies are judged only on request (`--down`); rollback judgments use
  the post-up catalog state in version order, not a one-at-a-time unwind.
- A snapshot is point-in-time: pending vs. applied-after-snapshot is
  offline-indistinguishable; scheduled re-export is the real mitigation.
