# Cerbero

Offline safety checks for Ecto migrations, judged against a committed snapshot
of your production database's *catalog metadata* — for PostgreSQL and CockroachDB.

**The claim, worded precisely:** cerbero detects a specific catalog-derivable
class of unsafe migrations, judged at export-time scale. It does not certify
migrations as safe; it judges the statement, not the moment.

## How it works

1. `mix cerbero.snapshot` exports catalog metadata (schema shapes, row/byte
   estimates, traffic counters, index/constraint validity) to
   `priv/repo/cerbero_snapshot.json` — a canonical, checksummed, human-diffable
   artifact you commit (or refresh on a CI cron — recommended past one
   deploy/week; a manually-refreshed artifact rots).
2. `mix cerbero.check` parses pending migrations (static AST — your code never
   runs), folds their effects into the catalog model, and judges each operation:
   lock mode × cost class × your production scale and traffic.
3. CI reads the exit code: 0 clean, 1 unsafe at `--fail-on` threshold,
   2 cerbero misconfigured. No database is reachable from CI.

Example finding:

    [error] unsafe_index_creation: SHARE lock blocks writes on public.events
    (~412M rows, stats 2026-07-01) for a full-table scan; use concurrently: true
    with @disable_ddl_transaction and @disable_migration_lock
    (priv/repo/migrations/20260801000000_add_events_payload_index.exs:5)

## Privacy boundary

The snapshot contains **identifiers, type names, enumerated keywords, booleans,
numbers, and timestamps — never expression text, never literals, never row
data**. `pg_stats` (histograms, most-common values) is permanently excluded.
Every SQL statement the exporter can run fits on one reviewable screen
(`Cerbero.Snapshot.Exporter.Queries`); `mix cerbero.snapshot --emit-sql` prints
it as a script a DBA can run with their own credentials, and `--from-file`
ingests the result.

What is *not* claimed: table/column names are exported (they already appear in
your migration files); row counts and byte sizes are business metrics and will
be visible to everyone with repo access, forever — opt into
`precision: :order_of_magnitude` to bucket them (planned; the config key is
reserved, bucketing lands with the exporter follow-up). A hot-standby snapshot
has degraded traffic stats (recorded and warned); a scrubbed subset copy
produces confidently wrong scale and is incompatible with scale judgment.

The checksum detects corruption and hand-edits. It is not tamper-proofing:
anyone who can commit can regenerate it.

## Why not excellent_migrations?

We like excellent_migrations. It is AST-only by identity: it judges the
migration text with no knowledge of the database, so it must assume the worst
everywhere — and teams drown in warnings on tables with 40 rows, annotate
everything with skips, and stop reading. Cerbero's differentiation is catalog
knowledge:

| | excellent_migrations | cerbero |
|---|---|---|
| Non-concurrent index | always warns | severity from actual rows/bytes/traffic; silent on small cold tables; correct per-partition recipe on partitioned parents |
| SET NOT NULL | always warns | silent if already NOT NULL; recognizes the validated-CHECK scan-skip (PG ≥ 12), including its own recommended two-step in raw SQL |
| Type change | cannot see the current type | `varchar(50)→varchar(255)`: info note only (lock_timeout caveat), never blocks CI; `int→bigint` on 412M rows: error, with the index rebuilds named |
| FK without index | cannot know | rule impossible without the catalog |
| ADD FOREIGN KEY | flags the statement | names the *referenced* table whose writes block while the referencing table is scanned |
| CockroachDB | n/a | engine-conditional verdicts + the CRDB limitation table (rejects before your deploy does) |
| Invalid index in prod, stale stats, history divergence | n/a | `snapshot_health` |
| Adoption on a 400-migration repo | re-annotate history | pending-only: zero findings at adoption |

Three of cerbero's ten rules are impossible without catalog knowledge; five
are severity upgrades where the catalog changes whether CI fails; one is kept
for self-consistency, plus `snapshot_health`, which judges the snapshot itself
rather than a migration. If you want AST-only checks with zero setup,
excellent_migrations remains the right tool — cerbero's no-snapshot mode
(`--no-snapshot`) gives you a comparable structural baseline plus a trial path.

## Requirements

Elixir ≥ 1.18. PostgreSQL ≥ 13 or CockroachDB ≥ v23.1. Postgres and
CockroachDB only — no adapter behaviour in v1.

## Configuration

`.cerbero.exs` (all optional):

    [
      rows_warning: 100_000,
      rows_error: 1_000_000,
      bytes_error: 1_073_741_824,
      hot_ops_per_sec: 1.0,
      headroom_days: 14,          # past this, thresholds shrink by headroom_multiplier
      headroom_multiplier: 0.5,
      stale_warn_days: 30,
      stale_degrade_days: 90,     # past this, all scale is treated as unbounded
      fail_on: :error,
      strict_concurrent_index: false,
      lock_timeout_attested: false,
      skip_checks: [],
      severity_overrides: %{},    # e.g. %{snapshot_health: :error}
      start_after: nil,
      precision: :exact,          # :order_of_magnitude is reserved (bucketing planned)
      schemas: ["public"],
      snapshot_path: "priv/repo/cerbero_snapshot.json",
      migrations_paths: ["priv/repo/migrations"]
    ]

Per-migration escape hatch (reason required, findings still shown at info):

    @cerbero_skip [{:unsafe_index_creation, "maintenance window 2026-07-20, comms sent"}]

## Known limitations

A snapshot is point-in-time; findings carry their stats dates; no wall-clock
duration estimates, ever. Pending vs. applied-after-snapshot is offline-
indistinguishable — scheduled re-export is the real mitigation. Lock queues,
long transactions, and concurrent DDL at deploy time are invisible offline:
cerbero judges the statement, not the moment. Dynamically-built operations
surface as `unknown_operation`, never silence. `down` bodies are not judged.
