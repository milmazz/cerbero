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
  table's blocked writes are called out), missing FK indexes, CockroachDB
  transactional-DDL restrictions, snapshot health (staleness, invalid indexes,
  history divergence, absent tables), unbatched DML at scale, and
  `CREATE INDEX CONCURRENTLY` attribute requirements.
- A raw-DDL safety net: classified raw SQL that no named rule owns is still
  judged by lock mode and cost — an ACCESS EXCLUSIVE-taking operation is
  never silent, and `TRUNCATE` carries an error-severity floor.
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

### Known limitations

- `precision: :order_of_magnitude` is reserved in configuration but bucketing
  is not yet implemented.
- `down` migration bodies are not judged.
- Raw-SQL `RENAME`, `ATTACH/DETACH PARTITION`, and `SET LOGGED/UNLOGGED`
  forms have no classifier patterns yet and surface as `unclassified_sql`
  warnings rather than typed findings.
- A snapshot is point-in-time: pending vs. applied-after-snapshot is
  offline-indistinguishable; scheduled re-export is the real mitigation.
