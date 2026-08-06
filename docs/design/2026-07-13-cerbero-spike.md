# Cerbero spike design — revised after adversarial review

Status: **revised, awaiting author sign-off**. Draft v1 was reviewed by two independent hostile reviewers (domain: Postgres/Ecto internals; product: adoption/scope). Every objection is adjudicated in the final section. No code exists yet; the first failing test is written only after this document is approved.

Decisions made with the author (2026-07-13):

- Raw SQL in `execute/1,2` is classified by a keyword heuristic; anything unclassifiable emits an explicit "cerbero cannot judge this" finding (default severity: **warning**, reachable by `--fail-on`). The `elixir-dbvisor/sql` package was evaluated and rejected for the spike: as of 0.5.0 its grammar (generated from the SQL 2016 BNF) contains no DDL at all — zero occurrences of `CREATE INDEX`, `ALTER TABLE`, `CONCURRENTLY`, or `NOT VALID` in lexer, parser, or tests. Since a fallback "unknown" path is required no matter what parser sits in front of it, the heuristic ships first; revisit if the library grows DDL coverage.
- The snapshot includes applied `schema_migrations` versions; `mix cerbero.check` judges only pending migrations.
- No wall-clock duration estimates. Findings state mechanism and scale; severity comes from configurable row-count/size/traffic tiers.
- Integrity is a sha256 checksum over canonical JSON — documented honestly as **corruption and hand-edit detection**, not tamper-proofing. Cryptographic signing is deferred; the format version bump that introduces it is the migration path.

**The claim, worded precisely** (this wording appears in the README and nowhere is it stronger): cerbero detects *a specific catalog-derivable class of unsafe migrations, judged at export-time scale*. It does not certify migrations as safe; it judges the statement, not the moment.

---

## 1. Snapshot contents

Rule of admission: **a field enters the snapshot only if a named v1 check consumes it, or it is required to interpret another field honestly** (e.g. `last_autoanalyze` qualifies `reltuples`; `stats_reset` qualifies the traffic counters).

### Instance level

| Field | Source | Why |
|---|---|---|
| `engine.name` (`postgres` \| `cockroachdb`) | `SELECT version()` + presence probe of `crdb_internal` | Every lock/cost judgment is engine-conditional. |
| `engine.version`, `engine.version_num` | `server_version_num` (PG); `crdb_internal.node_build_info` (CRDB) | Version-conditional verdicts (SET NOT NULL scan-skip on PG ≥ 12, FK NOT VALID on partitioned tables only on PG ≥ 18, CRDB limitation table). |
| `collected_at` (UTC ISO8601) | exporter clock | Staleness. |
| `database` | `current_database()` | Guards against snapshotting staging and believing it is prod. |
| `standby` (bool), `stats_provenance` | `pg_is_in_recovery()` | On a hot standby, `pg_stat_user_tables` is instance-local: `n_live_tup` ≈ 0 and analyze timestamps are NULL. The checker must know it is looking at degraded statistics (see §2, replica note). |
| `stats_reset` | `pg_stat_database.stats_reset` | Traffic counters are cumulative; without the reset time they cannot be read as rates. |
| `format_version`, `cerbero_version` | constants | Format evolution. |
| `applied_migrations` (sorted version strings) | the repo's migrations table, honoring Ecto's `:migration_source` config (name override) | Pending-only checking + staleness cross-check. The only user table the exporter ever reads, and only its version column. |
| `checksum` | sha256 of canonical JSON, checksum field nulled | Corruption/hand-edit detection. |

### Per table (user tables in configured schemas, default `public`)

- `schema`, `name`, `partitioned` (bool), `partition_of` (parent or null)
- `reltuples`, `relpages` (`pg_class`) — primary scale signal. PG ≥ 14 reports `-1` for never-analyzed; preserved as-is, interpretation is checker policy (§4). **Partitioned parents have no storage and autovacuum never analyzes them; the checker computes parent scale as Σ(partition stats), never from the parent row.**
- `n_live_tup`, `last_analyze`, `last_autoanalyze` (`pg_stat_user_tables`) — the honesty qualifier on every size-derived finding.
- `seq_scan`, `idx_scan`, `n_tup_ins`, `n_tup_upd`, `n_tup_del` (`pg_stat_user_tables`) — **traffic proxy**. Lock-queue damage tracks traffic, not table size: a metadata-only ACCESS EXCLUSIVE on a 10k-row `feature_flags` table read on every request is a classic outage. Zero additional privacy cost (counters). Read with `stats_reset`.
- `heap_bytes` (`pg_relation_size`), `total_bytes` (`pg_total_relation_size`) — rewrite cost tracks bytes. **On CRDB these functions are incomplete/version-dependent; the exporter uses `crdb_internal.table_span_stats` (or `SHOW RANGES` fallback) and the fields carry per-engine provenance; nullable.**

CRDB row stats come from `crdb_internal.table_row_statistics.estimated_row_count` and `SHOW STATISTICS` timestamps.

### Per column

- `name`, `type` (formatted with modifiers, e.g. `character varying(255)`), `not_null`, `identity` (bool), `generated` (`stored` | null)
- `default`: `{present: bool, volatile: bool, kind: sequence|expression|literal}` — **never the expression text** (§2). `volatile` derived server-side from `pg_get_expr` + `pg_proc.provolatile`; only the boolean crosses the wire.

### Per index

- `name`, `unique`, `primary`, `valid` (`indisvalid`), `method`, `partial` (bool — **not** the predicate), `bytes`
- `keys`: list of `{kind: "column", name: ...}` or `{kind: "expression"}` — expression text never exported.

### Per constraint

- `name`, `type` (`primary|unique|foreign_key|check|exclusion`), `columns`, `validated` (`convalidated`)
- FK: `references: {table, columns}`, `on_delete`, `on_update`
- CHECK: `is_not_null_check_on: column | null` — derived by the exporter when the constraint is exactly `(col IS NOT NULL)`, enabling the PG ≥ 12 scan-skip rule without exporting expression text.

### Interrogated and excluded

- **`pg_stats` (MCVs, histograms, correlation)** — literal row values. Permanently excluded; this is the privacy claim (§2), not a v1 deferral.
- **Expression text of any kind** (defaults, CHECK bodies, partial-index predicates, expression-index members) — can embed literals. Excluded; derived booleans instead. Cost: findings cannot quote definitions. Accepted.
- **Extensions**, **roles/grants**, **triggers, views, matviews, sequences, `n_dead_tup`/bloat, replication state, `pg_stat_activity`** — no v1 check consumes them; runtime state is stale by definition and its absence is documented as a limitation (§10).
- **Server GUCs** — the values that matter are the *migration session's*, which live in repo config and migration code, local to the checker.

A property worth stating: everything in the snapshot except the statistics numbers and applied versions is already derivable from the repo's own migration history (when that history is complete). The snapshot's genuinely new information is **scale, traffic, and index/constraint validity** — and it is ground truth where history replay is dead reckoning (squashed migrations, opaque raw SQL, out-of-band hotfixes).

## 2. Privacy boundary

The invariant: **identifiers, type names, enumerated keywords, booleans, numbers, and timestamps — never expression text, never literals, never row data.**

Enforcement, in layers:

1. **Query allowlist.** Every SQL statement the exporter can ever run lives as module attributes in one module (`Cerbero.Snapshot.Exporter.Queries`), reviewable in a single screen. No dynamic SQL beyond schema-name parameters. The only non-catalog read is the versions column of the migrations table. For DBA-mediated environments, `mix cerbero.snapshot --emit-sql` prints the exact queries as a reviewable script so a DBA can run them with their own credentials via psql and hand back the output for `mix cerbero.snapshot --from-file` to canonicalize and checksum (PG only in v1; CRDB via the mix task).
2. **Schema allowlist.** The snapshot JSON schema uses `additionalProperties: false` at every level; every string-valued field is an identifier, a formatted type, or a closed-enum member. A test validates every fixture and every exporter output against the schema; adding a free-text-capable field requires touching `privacy_test.exs`.
3. **Derivation server-side.** Facts that live inside expressions (`volatile?`, `is_not_null_check_on`) are reduced to booleans at export time; the text is discarded.
4. **Read-only session.** `SET default_transaction_read_only = on` + short `statement_timeout` after connect. Defense in depth, not the privacy mechanism.

What is *not* claimed, stated in the README:

- **Column and table names are exported.** They are schema metadata, and they already appear in cleartext in the repo's own migration files — which is also why an identifier-hashing mode is rejected as theater: anyone with repo access already has the names.
- **Row counts and byte sizes are business metrics** (a `subscriptions` row count is a revenue proxy) and will be visible to everyone with repo read access, in history, forever. Teams for whom this matters can use the opt-in `precision: :order_of_magnitude` export mode, which buckets counts and bytes to powers of ten — the severity tiers compare bucket floors, so verdicts survive; message precision degrades ("~10⁸ rows"). Exact is the default because human-diffable review benefits from real numbers.
- **Replica/scrubbed-copy caveat:** a hot standby produces degraded activity stats (the snapshot records `standby: true` and the checker warns); a scrubbed *subset* copy produces confidently wrong scale and is documented as incompatible with scale judgment. Privacy escape hatches and scale accuracy trade off against each other; the README says so instead of cashing the same check twice.

## 3. Snapshot format

One JSON file per Ecto repo, default `priv/repo/cerbero_snapshot.json`, committed to git — **or fetched in CI**: the documented primary workflow for teams beyond one deploy/week is a scheduled job (CI cron against prod or a replica) that re-exports and commits/uploads; the README ships that recipe, because a manually-refreshed artifact rots and a rotten artifact teaches teams to uninstall the tool.

- **Canonical encoding:** sorted keys, 2-space indent, tables sorted by `(schema, name)`, members sorted by name, LF endings. Canonicalization is ours (~60 lines) because the checksum must be stable across Elixir/OTP versions *and* because stable ordering is what makes PR diffs reviewable. Decoding uses stdlib `JSON` (Elixir ≥ 1.18; open question §9.1).
- **Checksum:** `sha256:<hex>` over canonical bytes with the checksum field nulled. `check` recomputes on load; mismatch is a hard exit-2 error. Documented as corruption/hand-edit detection — anyone who can commit can regenerate it; tamper-proofing is the deferred signing story.
- **Versioning:** integer `format_version`, starting at 1. Checker refuses newer ("upgrade cerbero") and older-than-supported ("re-export"); both refusal paths implemented and tested from day one. `additionalProperties: false` means additive fields require a version bump — deliberate; it keeps the privacy allowlist meaningful.
- **Staleness** — signals surfaced as findings, never silent decay, and calibrated so that *staleness degrades confidence rather than failing unrelated PRs*:
  1. `collected_at` age: **warning past 30 days** (a `snapshot_health` finding — a PR with no pending migrations still exits 0). **Past 90 days, scale degrades:** every judged table's row count is treated as *unknown → unbounded* (§4), so any risky operation fires at the warning tier or above and a stale snapshot cannot silently certify anything — but PRs that touch no migrations still pass. Both thresholds configurable; teams that want hard failure set the `snapshot_health` severity to error.
  2. **Growth headroom:** when the snapshot is older than 14 days (configurable), severity tiers are evaluated at 0.5× their thresholds — a table at 600k rows three weeks ago is judged as if at the 1M error tier. Point-in-time scale plus time equals unknown growth; headroom is the honest correction.
  3. Migration cross-check: a repo migration file with version ≤ max(`applied_migrations`) but absent from the list → snapshot and repo disagree about history — warning. Files present in `applied_migrations` are skipped as already-run.
  4. **Aged-pending heuristic:** a "pending" migration whose version timestamp predates `collected_at` — or is much older than the configured deploy cadence — has likely *already been deployed* (the snapshot just can't see it). Warning: "these migrations may already be applied; re-export." This matters because pending vs. applied-after-snapshot is offline-indistinguishable (§10).
  5. Per-table stats age: old `last_(auto)analyze` annotates findings on that table with reduced confidence and is a `snapshot_health` finding at scale.
  6. The check summary line always states the snapshot date and age ("judged against snapshot of app_prod, 2026-07-01, 12 days old") — so *non*-findings carry the caveat too.

### Pending-migration overlay (correctness requirement, not a feature)

If pending migration 1 creates `events_v2` and pending migration 2 indexes it, the snapshot has no `events_v2`. The checker folds each pending migration's structural effects into the catalog model before judging the next (`Cerbero.Catalog.apply/2`). The overlay folds effects from **both the Ecto DSL and classified raw SQL** — in particular `ADD CONSTRAINT ... CHECK (col IS NOT NULL) NOT VALID` + `VALIDATE CONSTRAINT`, which the classifier extracts including the column pattern (privacy is not implicated: migration source is already repo-local). Without this, rule 2 would false-positive on the exact safe pattern it recommends.

Scale-rule silencing applies **only** to tables created within the pending set (`born_this_deploy: true`) — and is revoked for a table that any pending migration also targets with classified DML (a created-then-mass-backfilled table is not "empty by construction"). A table **absent from the snapshot and not created by the pending set** is treated as *unknown scale → unbounded* and raises a `snapshot_health` error demanding re-export: absence is never safety. (Draft v1 silenced these; review correctly identified that as a false-negative factory — the flagship demo scenario shifted by one deploy would have passed silently.)

### No-snapshot structural mode

`mix cerbero.check` without a snapshot still runs: the catalog is built by replaying the repo's full migration history (the same `Catalog.apply/2` machinery), every table's scale is *unknown → unbounded*, structural rules (4, 6, 10) work where history is complete, and every finding is labeled "no snapshot: structural checks only, scale unknown". `start_after` config provides the pending cutoff. This is deliberately honest and deliberately noisy at scale-severity — it exists as the zero-friction trial path (try cerbero before asking security for prod access) and as the graceful degradation when a snapshot is unavailable, **not** as the recommended mode. History replay is dead reckoning: squashed history, opaque SQL, and out-of-band schema changes all degrade it, and unresolvable references surface as cannot-judge findings, never silence.

## 4. Rule model

Pipeline:

```
migration .exs ──Parser──▶ [Operation]        (typed structs + source loc)
[Operation] × Catalog ──DDL.Effects──▶ Effect (lock mode, cost class, scope)
Effect × TableStats × Config ──▶ Finding severity
```

**Operation** structs mirror Ecto DSL semantics: `%CreateIndex{concurrently:, unique:, table:, keys:}`, `%AlterTable{table:, ops: [...]}`, `%CreateTable{}`, `%RawSQL{classified: ... | :unknown}`, etc. Parsing is static AST analysis; migrations are never executed (§5). Only `up`/`change` is judged; `down` bodies are out of scope in v1 (documented).

**Effect** is derived by `Cerbero.DDL.Effects.derive(op, engine, version)`:

- `lock`: strongest lock per relation — `:access_exclusive | :share | :share_row_exclusive | :share_update_exclusive | :row_exclusive | :none`; CRDB: `:online_schema_change`, judged by the CRDB limitation table instead.
- `cost`: `:metadata_only | :full_scan | :rewrite` — the three outage mechanisms.
- `relations`: every relation touched with role (ADD FK touches referencing *and* referenced).
- `notes`: version-conditional facts, always naming the assumed engine version from the snapshot ("assuming PG 15 per snapshot; verdict changes on PG ≥ 18").

**`derive/2` is total.** An Operation that parses but has no Locks entry gets the conservative default — ACCESS EXCLUSIVE + rewrite + an explicit `unmapped_operation` finding — and a test asserts every Operation class the parser can emit has an explicit Locks entry per supported engine, so the conservative path is a tripwire, not a resting state. The finite-enumeration claim in §8 is enforced, not assumed.

The lock/cost mapping is **data** (`Cerbero.DDL.Locks`, keyed by operation class, engine, version range), verified empirically (§8 layer 4). The v1 PG table — now including the classes draft v1 omitted:

| DDL class | Lock | Cost |
|---|---|---|
| `CREATE INDEX` | SHARE | full_scan |
| `CREATE INDEX CONCURRENTLY` | SHARE UPDATE EXCLUSIVE | full_scan (non-blocking; not txn-safe; **unsupported on partitioned parents through PG 18** — per-partition recipe instead) |
| `DROP INDEX` / `DROP INDEX CONCURRENTLY` | ACCESS EXCLUSIVE / SHARE UPDATE EXCLUSIVE | metadata_only (finding recommends the CONCURRENTLY form) |
| `ADD COLUMN` (no/constant default, PG ≥ 11) | ACCESS EXCLUSIVE | metadata_only |
| `ADD COLUMN` volatile default; `ADD COLUMN ... NOT NULL` w/ volatile default | ACCESS EXCLUSIVE | rewrite |
| `ADD COLUMN ... GENERATED ALWAYS AS (...) STORED` | ACCESS EXCLUSIVE | **rewrite on every version** (must not be swallowed by the PG ≥ 11 constant-default rule) |
| `ADD PRIMARY KEY` / `ADD UNIQUE` (constraint or via unique index) | ACCESS EXCLUSIVE | full_scan (index build under AEL — the classic outage) |
| `SET NOT NULL` | ACCESS EXCLUSIVE | full_scan; PG ≥ 12 metadata_only iff validated `IS NOT NULL` CHECK exists (snapshot ∪ overlay) |
| `ADD CHECK` / `ADD CHECK NOT VALID` / `VALIDATE CONSTRAINT` (CHECK) | ACCESS EXCLUSIVE / ACCESS EXCLUSIVE / SHARE UPDATE EXCLUSIVE | full_scan / metadata_only / full_scan |
| `ADD FOREIGN KEY` (± NOT VALID) | SHARE ROW EXCLUSIVE on **both** tables | full_scan of referencing / metadata_only. NOT-VALID advice gated: unsupported on partitioned referencing tables before PG 18 — the tool must not recommend a statement that errors |
| `VALIDATE CONSTRAINT` (FK) | SHARE UPDATE EXCLUSIVE on referencing + ROW SHARE on referenced | full_scan (message must **not** claim writes to the referenced table are blocked — they aren't here) |
| `ALTER COLUMN TYPE` | ACCESS EXCLUSIVE | rewrite (+ index rebuilds, named from snapshot); metadata_only for binary-coercible pairs (in-code table: `varchar(n)→varchar(m≥n)`, `varchar→text`, precision widenings) — **still AEL; the lock-queue caveat is not dropped because cost is metadata** |
| `ATTACH PARTITION` | SHARE UPDATE EXCLUSIVE on parent, ACCESS EXCLUSIVE on child | full_scan of attached table unless a proving CHECK exists |
| `DETACH PARTITION [CONCURRENTLY]` | AEL / SUE (PG ≥ 14) | metadata_only |
| `SET LOGGED/UNLOGGED` | ACCESS EXCLUSIVE | rewrite |
| `TRUNCATE` | ACCESS EXCLUSIVE | metadata_only (but destructive — severity floor error via rule config) |
| `REINDEX` / `REINDEX CONCURRENTLY` | ACCESS EXCLUSIVE on index / SUE | full_scan |
| `DROP COLUMN`, `RENAME`, `SET/DROP DEFAULT` | ACCESS EXCLUSIVE | metadata_only |

**"Brief" ACCESS EXCLUSIVE is still dangerous** — acquisition queues behind any long-running query and queues everything behind it, and the damage scales with *traffic*, not table size. Therefore:

**Severity** — `severity(lock, cost, stats, traffic, config)`. Defaults, all configurable:

- `full_scan`/`rewrite` under a write-blocking lock: error ≥ 1M rows or ≥ 1 GB heap; warning ≥ 100k rows; info below.
- `metadata_only` under AEL: severity gates on **traffic ∨ rows** — warning when the table is hot (scan/write counters normalized by `stats_reset` age exceed a configurable rate) even at 10k rows; info otherwise. **An AEL-taking operation is never silent**: the floor is an info note carrying the lock-queue/`lock_timeout` caveat. Human format collapses info notes ("7 informational notes; -v to show") so the floor doesn't become noise.
- Row estimate policy: `max(reltuples, n_live_tup)` when `reltuples ≥ 0`, else `n_live_tup`; **partitioned parents: Σ over partitions**; if nothing is known, *unknown scale = unbounded, never small*.
- `born_this_deploy` tables: scale rules silenced (revoked on classified DML into the table, §3); engine rules still apply.
- `lock_timeout`: every AEL finding mentions it. `.cerbero.exs` accepts `lock_timeout_attested: true` (team affirms their migration sessions set one), which annotates rather than silences. Full idiom *detection* is an open question (§9.5).

**Findings** carry: check id, severity, message (mechanism + scale + stats date + assumed engine version), file:line, relations, engine, structured metadata.

## 5. Module boundaries

| Module | Owns | Explicitly does not own |
|---|---|---|
| `Cerbero.Snapshot` | Artifact struct; decode/validate/canonical-encode; checksum; format-version gate; staleness computation | DB access; rule knowledge |
| `Cerbero.Snapshot.Exporter` (+ `.Queries`) | Engine detection; all catalog SQL per engine; `--emit-sql`; building a Snapshot from a connection or DBA-returned output | Judging migrations; writing files (task does that) |
| `Cerbero.Catalog` | Queryable in-memory model: table/index/constraint lookup, `apply/2` overlay (DSL + classified SQL effects), history replay for no-snapshot mode, row-estimate/traffic policy | JSON, checksums, DB access |
| `Cerbero.Migration.Parser` | `.exs` source → `[%Migration{}]` via static AST; Ecto DSL coverage incl. module attributes (`@disable_ddl_transaction`, `@disable_migration_lock`, `@cerbero_skip`); never executes user code | SQL classification internals; judging safety |
| `Cerbero.SQL.Classifier` | Normalization + anchored keyword patterns → classified DDL (including the `CHECK (col IS NOT NULL)` column extraction) or `:unknown`; DML detection (UPDATE/DELETE/INSERT INTO ... SELECT + target table); multi-statement detection | Being a SQL parser; DML *analysis* beyond detection |
| `Cerbero.DDL.Locks` / `.Effects` / `.CRDB` | The (operation, engine, version) → lock/cost data; the CRDB limitation table (same data-not-conditionals rigor); total `derive/2` with conservative default | Severity policy |
| `Cerbero.Check` (behaviour) + `Cerbero.Check.Runner` | `c:id/0`, `c:run(migration_or_op, catalog, config) :: [Finding.t()]`; runner orders pending migrations, threads overlay, applies skips/config | Output formatting, exit codes |
| `Cerbero.Finding`, `Cerbero.Config` | Finding struct; `.cerbero.exs` (thresholds, headroom, traffic rates, multi-repo entries, skip_checks, attestations) | — |
| `Cerbero.CLI.Check` / `Cerbero.CLI.Snapshot` | argv parsing, orchestration, formatters (human/JSON), exit codes; injectable clock and IO | — |
| `Mix.Tasks.Cerbero.Snapshot` / `.Check` | ~5-line shims | logic of any kind |

Static AST parsing (not compiling/running migrations) is deliberate: Ecto's DSL macros call `Ecto.Migration.Runner` — a private, repo-bound process — by module name; intercepting means replicating private API. AST analysis is pure and runs no user code in CI. Cost: dynamically-generated operations are invisible — the parser emits `unknown_operation` (default severity warning), never silence.

The Check behaviour stays (spec constraint, born from real Credo-check pain); internal rules are its first consumers, so it costs nothing extra.

## 6. Initial rule set

Legend: **(a)** = `excellent_migrations` covers it free today; **(a+)** = EM has a cruder always-fires version, the snapshot changes the verdict; **(b)** = impossible without catalog knowledge (snapshot, or history replay in degraded mode).

1. **`unsafe_index_creation`** (a+) — non-concurrent `create/drop index`. Silent-by-default on small *cold* tables and `born_this_deploy` tables; severity scales with size and traffic. **Partitioned parents get the correct recipe** (per-partition `CONCURRENTLY` + `ON ONLY` + `ATTACH`) instead of a `concurrently: true` suggestion that errors. On CRDB the *lock* warning is suppressed (index builds are online) but a **cost finding remains** — a 412M-row backfill consumes foreground cluster resources; total suppression deletes real signal. `strict_concurrent_index: true` config restores EM's always-fire behavior for habit-enforcing teams.
2. **`not_null_on_populated_table`** (a+) — silent if already NOT NULL in snapshot; metadata-only verdict on PG ≥ 12 when a validated `IS NOT NULL` CHECK exists **in snapshot ∪ overlay** (so the tool recognizes its own recommended two-step, including the raw-SQL form); else severity by row count with the two-step spelled out.
3. **`column_default_rewrite`** (a+, honestly re-scoped) — with the PG ≥ 13 floor, constant defaults are metadata-only, so this rule's rewrite arm fires on **volatile defaults and `GENERATED ... STORED` columns** (the latter rewrites on *every* version and is the trap the PG ≥ 11 folklore hides); size-scaled; CRDB: online backfill cost note instead of lock warning.
4. **`column_type_change`** (b) — the current type comes from the catalog: `varchar(50)→varchar(255)` metadata-only (silent); `int→bigint` on 412M rows: AEL + rewrite + the N index rebuilds named from the snapshot — error. On CRDB, consults the CRDB limitation table: type changes on indexed/constrained/computed columns are rejected by the engine per version — error *before* deploy fails.
5. **`fk_validation_scan`** (a+) — ADD FK without `validate: false`: severity from **both** tables' scale; the referenced-table lock ("writes to `orgs` (41M rows) are blocked while `events` (412M rows) is scanned") is the non-obvious outage EM cannot see. NOT-VALID advice version-gated for partitioned referencing tables (< PG 18).
6. **`fk_missing_index`** (b) — new FK, no covering index on the referencing column in catalog ∪ overlay.
7. **`crdb_transactional_ddl`** (b) — engine = cockroachdb: multiple DDL in one transactional migration → warning (transactional schema-change restrictions); `ALTER COLUMN TYPE` in a migration with other DDL → error; standalone type change on an indexed column → error per the limitation table. Plus engine-conditioning that suppresses PG-only lock warnings on CRDB.
8. **`snapshot_health`** (b) — invalid index in prod (a failed `CONCURRENTLY` build costing writes and providing nothing), stale stats at scale, history divergence, snapshot age, absent-table demands (§3). Runs regardless of pending migrations.
9. **`dml_in_migration`** (a+) — classifier-detected `UPDATE`/`DELETE`/`INSERT INTO ... SELECT` against a table above threshold: single-transaction backfill warning with the row count. EM flags Repo calls; cerbero flags the raw-SQL form *and* scales it. Judging batching correctly is out of scope; *flagging* an unbatched 412M-row UPDATE is not.
10. **`concurrent_index_requires_attributes`** (a) — `concurrently: true` without both `@disable_ddl_transaction` and `@disable_migration_lock` → error. EM has this; cerbero needs it for self-consistency (rule 1's own advice must not produce a deploy-time failure and an invalid index).

Meta-findings: `unclassified_sql`, `unknown_operation`, `unmapped_operation` — all default severity **warning**: the escape routes for the worst migrations must be reachable by `--fail-on`.

**Honest tally:** of the ten, three are impossible without catalog knowledge (4, 6, 7 — plus 8, which isn't a migration check), five are upgrades where catalog data changes whether the rule fires and at what severity, one (10) is a pure EM-parity rule kept for self-consistency. None are restatements. v1 deliberately does **not** reimplement EM's app-level-breakage rules (renames, drop-column-referenced-by-code). The differentiation rests on 4/6/7/8, on severity-that-tracks-reality, and on brownfield adoptability: a 400-migration repo gets zero findings at adoption (pending-only) and findings proportional to actual risk afterward. The README's "why not excellent_migrations" comparison is written **before** the exporter (§9.7) — it is the pitch, and writing it first tests whether the pitch survives contact with paper.

## 7. CI ergonomics

- **Formats:** `--format human` (grouped per migration, `file:line`, color with `NO_COLOR`/non-TTY detection, info notes collapsed) and `--format json` (stable versioned shape). SARIF deferred — a mechanical adapter over the JSON shape.
- **Exit codes:** `0` none at/above threshold; `1` findings at/above `--fail-on` (default `error`); `2` operational errors (missing/corrupt snapshot, unsupported format version, bad config) — CI distinguishes "unsafe migration" from "cerbero misconfigured". Staleness is *not* exit-2 (§3): it degrades scale to unbounded and surfaces findings.
- **Baselining:** pending-only checking *is* the baseline; `start_after` covers dev snapshots and no-snapshot mode.
- **Escape hatch:** `@cerbero_skip [{:unsafe_index_creation, "maintenance window 2026-07-20, comms sent"}]` — reason required (empty fails); skipped findings still emitted at info with the reason visible in output and PR review. Global `skip_checks` in config.
- The summary line always names the snapshot, its date, and its age.

## 8. Test strategy

Red-green-refactor throughout; layers order kinds of tests, not phases.

- **Layer 0 — pure unit:** SQL classifier (table-driven, incl. DML detection and the IS-NOT-NULL extraction), `DDL.Locks`/`DDL.CRDB` lookups + **totality test** (every parser-emittable Operation class has an entry per engine), severity function (incl. traffic gating, headroom, partition summation), canonical encoder, checksum, config, staleness math (clock injected).
- **Layer 1 — fixture-based pure checks (the backbone):** `(migration fixture, snapshot fixture) → findings`, table-driven per rule. Fixtures: `huge_table.json`, `partitioned.json` (parent + partitions — the Σ policy and the CIC-recipe path), `invalid_index.json`, `crdb_25.json`, `empty_dev.json`, `stale.json`, `standby.json` (degraded stats provenance), `fk_no_index.json`, `hot_small_table.json` (traffic gating). Migration corpus under `test/fixtures/migrations/{safe,unsafe}/`, one pair per rule minimum, plus sanitized real production CRDB migrations (approval: §9.6). Includes the adversarial pairs the review surfaced: absent-table-not-in-pending, create-then-backfill, the safe NOT NULL two-step in raw SQL.
- **Layer 2 — golden files:** CLI output (human and JSON) under `test/golden/`, byte-compared, `UPDATE_GOLDEN=1` regen; injected clock/IO; ANSI disabled.
- **Layer 3 — single-DB integration (`@tag :postgres`):** exporter vs Dockerized PG; `setup_all` seeds a schema exercising every snapshot feature (partitioned table, FK web, partial/expression indexes, generated + identity columns, a CHECK `IS NOT NULL`, an index flipped invalid via `UPDATE pg_index`); read-only assertions; privacy schema validation of real output; export → decode → checksum round-trip.
- **Layer 4 — dual-engine differential (`@tag :integration`):** same seed vs PG and single-node CRDB; engine detection; both snapshots validate; engine-specific provenance (sizes via `table_span_stats`). **Lock-verification suite** — the empirical anchor: for each PG entry in `DDL.Locks`, open a transaction, execute a representative statement, read `pg_locks` for the backend's locks on the target relation, assert the mapped mode, roll back. CI matrix PG 13 + PG 16; one CRDB version. On CRDB, assert the observable facts behind rules 7 and the limitation table (e.g. type-change-in-txn rejection). Budget < 60 s; excluded from default `mix test`.
- **Property-based, narrowly:** (1) canonical encode/decode round-trip + checksum stability under key permutation; (2) parser totality — generated/mutated migration ASTs never crash, always yield operations or `:unknown_operation`. Generative DDL→lock property rejected: ~30 finite classes whose only honest oracle is the real database; *enforced* enumeration (layer 0 totality + layer 4 verification) dominates generation.
- **First failing test:** `test "decodes and checksum-verifies the v1 huge_table fixture"` against a hand-authored `huge_table.json` — forces every §3 format decision into review before any exporter code exists.

## 9. Open questions (author decides — see also Escalations)

1. **Elixir floor:** stdlib `JSON` requires ≥ 1.18; or ≥ 1.15 + `jason`?
2. **Threshold defaults:** 100k/1M rows, 1 GB, the traffic rate, and the 14-day/0.5× headroom need calibration against your production incident history.
3. **Engine floors:** PG ≥ 13, CRDB ≥ v23.1 proposed. Confirm against work's CRDB version.
4. **Credential path** for `mix cerbero.snapshot`: `--repo` + `--url` + `--emit-sql`/`--from-file` proposed. Where do you expect it to run — bastion, prod console, CI with replica access?
5. **`lock_timeout` idiom detection** beyond the attestation flag: is there a checkable convention worth chasing?
6. **Employer approval** for publishing sanitized production migrations as fixtures.
7. **README-first:** the "why not excellent_migrations" comparison is written before exporter code. Agreed?
8. **Hex name availability** for `cerbero`.
9. **Support surface:** README states Postgres + CockroachDB only; `engine` closed enum; no adapter behaviour in v1.

## 10. Known limitations (documented, not solved)

- A snapshot is point-in-time; estimates carry their dates; headroom and unbounded-degradation compensate coarsely, not precisely. No duration claims, ever.
- **Pending vs. applied-after-snapshot is offline-indistinguishable.** A migration deployed after the snapshot looks pending; the aged-pending heuristic (§3.4) warns, but cannot know. Scheduled re-export is the real mitigation.
- Lock queues, long-running transactions, replication lag, concurrent DDL at deploy time are invisible offline. Cerbero judges the *statement*, not the *moment*; AEL findings say so.
- Static AST cannot see dynamically-built operations — surfaced as `unknown_operation`, never silence. `down` bodies are not judged in v1.
- History replay (no-snapshot mode) degrades with squashed history, opaque SQL, and out-of-band schema changes; degradation is surfaced, not hidden.

## Dependencies

`ecto_sql`, `postgrex`, stdlib `JSON` (or `jason` per §9.1). Test-only: `stream_data`. Docker for integration tests. Nothing else.

## Definition of done (restated)

`mix cerbero.snapshot` against a seeded "production" produces a committed artifact; `mix cerbero.check` on a branch adding a non-concurrent index to the 412M-row table fails CI with: check id, `file:line`, "SHARE lock blocks writes on public.events (~412M rows, stats 2026-07-01) for a full-table scan", the correct remediation for the table's shape (plain vs. partitioned), and exit code 1 — with no database reachable from CI. No existing Elixir tool can produce that sentence.

---

# Adjudication of adversarial reviews

Reviewer 1 = hostile Postgres/Ecto domain expert. Reviewer 2 = hostile product/scope adversary. Every objection answered.

## Reviewer 1 (domain)

| # | Objection | Verdict | Response |
|---|---|---|---|
| 1 | "Absent from fresh snapshot ⇒ scale rules silenced" is a false-negative factory (post-snapshot deploy + backfill + new index passes silently) | **Accept** | Draft policy deleted. Silencing now only for tables created *within the pending set*, revoked on classified DML into them; absent-and-not-pending ⇒ unbounded scale + `snapshot_health` error; aged-pending heuristic added. §3. The reviewer's deeper point — pending vs. applied-after-snapshot is offline-indistinguishable — is now a named limitation (§10). |
| 2 | Partitioned parents: `reltuples`/`n_live_tup` = 0 ⇒ silent verdicts; CIC recommendation errors on partitioned parents | **Accept** | Parent scale = Σ(partitions); rule 1 emits the per-partition recipe; `partitioned.json` fixture in layers 1 and 4. §1, §4, §6.1. |
| 3 | Lock table not closed-world; unmapped-but-parseable ops fall through silently | **Accept** | `derive/2` made total with conservative default (AEL + rewrite + `unmapped_operation` warning); layer-0 totality test; missing classes (ADD PK/UNIQUE, GENERATED STORED, ATTACH/DETACH, SET LOGGED, TRUNCATE, REINDEX, identity) added to the table. §4. |
| 4 | Unclassified SQL/DML has no severity — the escape route for the worst migrations (unbatched 412M-row UPDATE exits 0) | **Accept** | Meta-findings default to warning, reachable by `--fail-on`; new rule 9 `dml_in_migration` flags keyword-detectable UPDATE/DELETE/INSERT-SELECT at scale. §6. |
| 5 | AEL severity gated on rows is the wrong proxy; hot small tables are the classic lock-queue outage; lock_timeout check should be v1 | **Accept (modified)** | Traffic counters (`seq_scan`, `idx_scan`, `n_tup_*`, `stats_reset`) added to snapshot at zero privacy cost; AEL severity gates on traffic ∨ rows; AEL never silent (info floor, collapsed in output). lock_timeout: attestation config + caveat in every AEL finding ships in v1; full idiom *detection* stays an open question (§9.5) because the idiom space is unbounded and a half-right detector is worse than an attestation. |
| 6 | Snapshot age policy ignores growth; defaults indefensible for high-ingest tables | **Accept** | Growth headroom multiplier (0.5× thresholds past 14 days, configurable); degradation-to-unbounded at 90 days replaces the 120-day hard error; summary line states snapshot age so non-findings carry the caveat. §3. |
| 7 | Tool can't see its own recommended safe patterns: (a) raw-SQL CHECK two-step false-positives rule 2; (b) CIC advice without the two module attributes fails at deploy | **Accept** | (a) Classifier extracts the `CHECK (col IS NOT NULL)` pattern (privacy not implicated — repo-local source); overlay folds DSL + classified SQL constraints. (b) New rule 10. §3, §6. |
| 8 | CRDB divergence broader: sizes unreliable via pg_relation_size; total rule-1 suppression deletes real cost signal; ALTER COLUMN TYPE limitations exceed rule 7 | **Accept** | Sizes via `crdb_internal.table_span_stats` with provenance; rule 1 on CRDB → cost finding, not silence; `Cerbero.DDL.CRDB` limitation table keyed by version (type change on indexed/constrained columns → error). §1, §4, §6. |
| 9 | Scrubbed-replica escape hatch silently destroys the statistics the product runs on | **Accept** | `standby`/`stats_provenance` fields; checker warns on degraded stats; README states subset-scrub and scale judgment are mutually exclusive. §1, §2. |
| 10 | Version skew across the snapshot's legal lifetime; version-conditional verdicts unstated | **Accept** | Findings name the assumed engine version; version-conditional verdicts say so; FK-NOT-VALID-on-partitioned gate (PG 18) encoded. §4. |
| 11 | Mapping nuances: DROP INDEX CONCURRENTLY; FK VALIDATE ≠ CHECK VALIDATE lock profile; binary-coercible still AEL; partitioned FK advice gate | **Accept** | All four folded into the Locks table and message requirements. §4. |
| 12 | sha256 is corruption detection wearing integrity's name; add git-history row-count regression heuristic | **Accept naming / Reject heuristic** | Docs renamed honestly (§3). The git-history comparison is rejected for v1: it makes the checker's verdict depend on git state (shallow clones, rebases, no-git environments) — operational fragility in exactly the environment (CI) the tool must be boring in. |
| 13 | Privacy sound on expression text, silent on business metrics (row counts in git) | **Accept** | README "not claimed" section extended; opt-in `precision: :order_of_magnitude` bucketing added (§2). |
| 14 | Ecto surface gaps: `:migration_source` rename, prefixes, down bodies | **Accept** | Exporter honors `:migration_source`; prefix/schema matching documented; up-only scope stated (§4, §10). |

## Reviewer 2 (product/scope)

| # | Objection | Verdict | Response |
|---|---|---|---|
| 1 | The plan refutes its own architecture: rules 4/6 are derivable from history replay; invert to offline-first with snapshot as optional enrichment | **Reject the inversion; accept a bounded degraded mode** | History replay as *foundation* fails in exactly the mature repos this tool targets: squashed/pruned migrations, years of raw SQL the classifier can't fully resolve (errors compound over hundreds of files in a way they don't over a handful of pending ones), and out-of-band schema changes. The snapshot is ground truth; replay is dead reckoning — and the reviewer's own remedy would rebuild EM's epistemic position with more machinery. Scale severity — the actual outage discriminator and the product's thesis — needs production data, period. **Accepted from it:** the no-snapshot structural mode (§3), reusing the overlay machinery as the zero-friction trial path and graceful degradation. That captures the adoption value of the inversion without surrendering the foundation. |
| 2 | Prod-access approval unvalidated and existential; pgroll_ex (143 downloads) predicts the outcome; validate with three external teams; make the exporter a reviewable SQL file | **Accept (b), Escalate (a)** | The `--emit-sql`/`--from-file` DBA path is accepted (§2) — a static reviewable script is categorically easier to clear security review than "run our mix task against prod". Pre-validation with named external teams is escalated (E1): it's the author's evenings and they *are* the first user; but the reviewer is right that if no second team can ever run the exporter, the (a+) rules degrade to EM parity — the author should decide how much validation precedes the build. The pgroll_ex comparison is noted but discounted: pgroll_ex wrapped an executor nobody asked for; cerbero's failure mode is different and the no-snapshot mode narrows it. |
| 3 | Committed-snapshot sociology: day-121 stale error on an unrelated PR teaches teams to uninstall | **Accept** | Staleness redesigned: warnings don't fail unrelated PRs; past the degradation age, scale becomes unbounded (bites only PRs with pending migrations — exactly the PRs that should care); scheduled-refresh recipe documented as the primary workflow. §3, §7. |
| 4 | CRDB is a niche within a niche consuming a third of the budget; cut from public v1 | **Reject; escalate positioning** | Rejected on the project's own constraints: CRDB compatibility is the author's stated edge and the design brief explicitly forbids making it a bolt-on; the first production user (author's employer) is CRDB-shaped, and reviewer 1 independently demonstrated the CRDB rules are *under*-built, not over-built. Cost containment accepted in spirit: CRDB testing bounded to one version, limitation table scoped to facts rules 7/4 consume. Whether the public README *leads* with CRDB or lists it as supported is escalated (E2). |
| 5 | Differentiation thinner than claimed: rule 1's suppression teaches bad habits; rule 3 obsolete within the PG ≥ 13 floor; rule 5 cosmetic; rebuild pitch on 4/6/8 | **Partial** | Rule 1: default suppression on small *cold* tables stands — signal-to-noise is the product; teams annotating everything stop reading, which is the incumbent's documented failure. `strict_concurrent_index` config added for habit-enforcing teams. Rule 3: re-scoped honestly — its value inside the version floor is volatile defaults + `GENERATED STORED` (which rewrites on every version). Rule 5 "cosmetic" is rejected: severity gating changes *whether CI fails*, and the referenced-table lock is a real, invisible-to-EM outage. Pitch rebuilt around 4/6/7/8 + severity-that-tracks-reality (§6 tally, §9.7 README-first). |
| 6 | Scope: cut checksum+canonical encoder, plugin behaviour, Layer 4, golden files | **Reject (all four)** | Each is pinned by an explicit project constraint the reviewer wasn't shown: the format must be "versioned, human-diffable, and checksummed" (canonical ordering *is* the diffability mechanism); checks-as-behaviour is a stated design constraint from real Credo-check pain; golden-file testing is mandated; Layer 4's dual-engine differential is the empirical anchor for the lock table — the one part of the tool that must be *correct, not approximate*. The checksum-is-theater point is conceded in naming (R1.12) but the 60-line encoder pays for itself in diffability alone. |
| 7 | Build plan without adoption plan; write the comparison README first; consider contributing to EM instead | **Accept README-first; Escalate the rest** | README + "why not excellent_migrations" comparison moves ahead of exporter code (§9.7) — it is the pitch, and writing it first tests the pitch. ElixirForum validation timing and the EM-contribution question are escalated (E3): strategic calls only the author can make. Noted against the EM option: EM's identity is AST-only-no-DB; a catalog-aware mode is a philosophical fork of EM either way, which is evidence for a separate tool — but the distribution argument (4M downloads) is real. |
| 8 | Privacy residual: row counts are business metrics; offer identifier hashing and bucketed counts | **Accept bucketing; Reject hashing** | Opt-in order-of-magnitude bucketing added — the reviewer's observation that the checker consumes tiers, not exact counts, is correct, so bucketing survives the rule of admission; exact stays default for diff review. Identifier hashing rejected as security theater: every table and column name already appears in cleartext in the same repo's migration files, so hashing the snapshot's copies protects nothing from repo readers. §2. |

## Changelog (draft → revised)

1. **Killed the absent-table silence** — the worst false negative: absence from snapshot is now unbounded scale + a demand for re-export; `born_this_deploy` narrowed to the pending set and revoked on DML into the table (R1.1).
2. **Partition correctness**: Σ-of-partitions scale policy, per-partition CIC recipe, partitioned fixtures (R1.2).
3. **Closed-world lock table**: totality of `derive/2` with conservative default + tripwire finding; nine missing DDL classes added incl. ADD PK/UNIQUE and `GENERATED STORED` (R1.3).
4. **Meta-findings get teeth** (warning default) and new rule 9 `dml_in_migration` for raw-SQL backfills at scale (R1.4).
5. **Traffic-aware AEL severity**: five `pg_stat_user_tables` counters + `stats_reset` added to the snapshot; hot-small-table gating; AEL never silent; lock_timeout attestation config (R1.5).
6. **Staleness rework**: growth headroom (0.5× thresholds past 14 days), degrade-to-unbounded at 90 days instead of hard failure, aged-pending heuristic, snapshot age on the summary line, scheduled-refresh as the documented primary workflow (R1.6, R2.3).
7. **Self-consistency**: classifier extracts the IS-NOT-NULL CHECK pattern so the overlay recognizes the tool's own recommended two-step; new rule 10 requiring both migration attributes with `concurrently: true` (R1.7).
8. **CRDB deepened, not trimmed**: `table_span_stats` sizes with provenance, rule-1 suppression → cost finding, versioned CRDB limitation table incl. type-change-on-indexed-column (R1.8, contra R2.4).
9. **Replica honesty**: `standby` + stats provenance fields, degraded-stats warning, subset-scrub caveat (R1.9).
10. **Version skew**: findings name the assumed engine version; FK-NOT-VALID partitioned gate (PG 18); FK vs CHECK VALIDATE lock profiles split; DROP INDEX CONCURRENTLY recommendation (R1.10, R1.11).
11. **Honest naming**: checksum documented as corruption/hand-edit detection (R1.12/R2.6); privacy "not claimed" extended to scale metrics with opt-in order-of-magnitude bucketing (R1.13/R2.8).
12. **Ecto surface**: `:migration_source` honored, up-only scope stated (R1.14).
13. **No-snapshot structural mode** as trial path and graceful degradation — bounded, labeled, reusing overlay machinery (R2.1 partial, R2.2).
14. **DBA path**: `--emit-sql` / `--from-file` reviewable-SQL export flow (R2.2).
15. **README-first**: the comparison document precedes exporter code (R2.7).
16. **Rule set 8 → 10**; tally restated honestly (3× impossible-without-catalog + health, 5× upgrades, 1× parity-for-self-consistency); `strict_concurrent_index` knob (R2.5).
17. **Claim narrowed** everywhere: cerbero detects a catalog-derivable class of unsafe migrations at export-time scale; it never certifies safety.

## Escalations (author must decide)

- **E1 — Validation before building** (R2.2): talk to external teams about exporter-against-prod approval before writing it, or validate by shipping? The no-snapshot mode and `--emit-sql` path lower the stakes either way. Related: §9.4 (where does the snapshot task run in your org?).
- **E2 — CRDB positioning** (R2.4): does the public README lead with CockroachDB support or list it as secondary? Design keeps CRDB first-class regardless (spec constraint), but positioning affects who shows up in the issue tracker.
- **E3 — Forum RFC / EM relationship** (R2.7): post the comparison README to ElixirForum before or after the spike ships? And: is contributing a catalog-aware mode to excellent_migrations a path you'd entertain, given its 4M-download distribution vs. its AST-only identity?
- **E4 — lock_timeout detection** (R1.5, §9.5): is the attestation flag enough for v1, or do you know a checkable idiom in your codebases worth encoding?
- **E5 — Threshold calibration** (§9.2): row/byte/traffic tiers, headroom window and multiplier, staleness ages — these should come from your incident history, not my defaults.
- **E6 — Fixture corpus approval** (§9.6): employer sign-off for sanitized production CRDB migrations in a public repo.
- Plus the mechanical open questions: Elixir floor (§9.1), engine floors (§9.3), hex name (§9.8).
