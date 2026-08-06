## Context

You are working with a senior Elixir engineer (10 years) who contributes to Ecto, Ecto SQL, ex_doc, and Hex, and who is currently running a production Postgres → CockroachDB migration at work. Assume deep familiarity with Ecto internals, Postgrex, Oban, and Postgres locking. Do not explain Elixir basics. Be direct, be precise, and push back when a design is weak — agreement is worthless here.

The repo is an empty `mix new cerbero`. Nothing has been written yet.

## What cerbero is

Ecto has no idea how large your tables are. `Ecto.Migrator` will happily run a migration that takes an `ACCESS EXCLUSIVE` lock on a 400M-row table and take production down. The existing Elixir tool, `excellent_migrations`, is **pure AST static analysis and never touches a database** — so it cannot distinguish `SET NOT NULL` on 2,000 rows (fine) from the same statement on 400M rows (an outage). Ruby's `strong_migrations` is at least Postgres-version-aware; Elixir has nothing equivalent.

**The insight cerbero is built on:** the facts needed to judge a migration live in _production_, but the judgment must happen _locally and in CI_, where production is unreachable and should stay that way.

So: **split collection from analysis.**

- An **exporter** runs read-only against production (or a replica) and emits a small, signed, **metadata-only** artifact — no rows of customer data, ever.
- The snapshot is committed to the repo (or fetched in CI).
- A **checker** runs fully offline and deterministically: `(migration AST + snapshot) → verdict`.

This is also the security story that survives an enterprise review: _CI never opens a connection to production, and no customer data leaves the network._

## Scope of this spike — read the non-goals carefully

**In scope, and nothing else:**

1. `mix cerbero.snapshot` — connect read-only to a database, emit a metadata-only catalog snapshot to disk.
2. `mix cerbero.check` — parse Ecto migration files, cross-reference the snapshot, emit findings with severities and a CI-appropriate exit code.

**Explicitly out of scope. Do not design for these, do not leave hooks for them, do not mention them in the plan:**

- pgroll integration, view-based multi-version schemas, `search_path` juggling
- Any migration _executor_, backfill runtime, or Oban integration
- Dashboards, web UI, hosted services, history databases
- Multi-language SDKs, plan IRs, open interchange specs
- Licensing, monetization, or commercial tiers
- Replacing or forking `excellent_migrations`

Scope creep is the primary risk to this project. The spike must be shippable to Hex in a few weekends by one person working evenings. If a decision can be deferred, defer it.

## Design constraints

- Pure Elixir. Deps limited to `ecto_sql`, `postgrex`, `jason` (or `:json`), and dev-only tooling. Justify anything else.
- `mix cerbero.check` **must not require a database connection.** This is the core architectural constraint; violating it collapses the whole idea back into a linter.
- The snapshot format is versioned, human-diffable, and checksummed. It will be committed to git and reviewed in PRs.
- Target Postgres first, but **detect and accommodate CockroachDB** — differing catalog surfaces, differing lock semantics, differing "safe" operations. The author's edge is CRDB compatibility knowledge; the design must not make that a bolt-on.
- Checks are a behaviour, not a hardcoded list. The author has already had to write custom Credo checks at work because `excellent_migrations` couldn't express the rules his team needed; extensibility is the lesson learned, not a nice-to-have.

## Test-driven, without exception

Every line of production code in this project is written in response to a failing test. Not "tests afterwards", not "tests for the tricky parts" — red, green, refactor, from the first commit. The plan must make this possible, and if a design decision makes something hard to test, that is an argument against the design, not an argument for skipping the test.

This is not dogma for its own sake. The product's entire claim is _"trust our judgment about your production database."_ A tool that tells you a migration is safe, and is wrong, is worse than no tool at all. The test suite is the product's credibility.

The plan must therefore specify, before any implementation:

- **The test taxonomy.** Which layers are unit-tested with fixtures, which need a real database, and which need _two_ real databases (Postgres and CockroachDB, via Docker) because the whole point is that they differ.
- **Snapshot fixtures.** Checked-in snapshot artifacts representing realistic shapes — a 400M-row table, a table with an invalid index, a CRDB snapshot, an empty dev database. These are the backbone of the suite: because `mix cerbero.check` takes no database connection, nearly every rule is testable as a pure function of `(migration source, snapshot fixture) → findings`. That is a large, underappreciated gift of the architecture. Exploit it.
- **Migration fixtures.** A corpus of real Ecto migrations, safe and unsafe, including ones drawn from the author's actual production CRDB work.
- **Golden-file testing** for the two Mix tasks' output, so CI ergonomics don't regress silently.
- **A property or generative angle**, if one is warranted, for the DDL → lock-level mapping — argue for or against it rather than assuming.
- **How the exporter is tested against a real database** without becoming slow enough that people skip it.

Write the failing test first, in every case. If you catch yourself writing implementation to "make the tests easier to write later," stop.

## What I want from you first — a plan, not code

Do **not** start writing modules. Produce a written design covering:

1. **Snapshot contents.** Exactly which catalog objects and columns. Interrogate each one: `pg_class.reltuples`/`relpages`, `pg_stat_user_tables.n_live_tup`, index definitions and `indisvalid`, constraints, FKs, column types and defaults, table/index sizes, extensions, `server_version`, CRDB detection. What is genuinely needed to _judge a migration_, and what is speculative bloat? Argue for exclusions as hard as inclusions.
2. **Privacy boundary.** Prove no row data can leak. Column _names_ and types are in; `pg_stats` most-common-values are not (they contain literal data). Be paranoid and explicit — this is a load-bearing claim in the product's positioning.
3. **Snapshot format.** JSON schema, versioning strategy, staleness handling (a snapshot from three months ago is a lie — how does the tool know and what does it do about it?).
4. **The rule model.** How a migration AST maps to (a) the DDL it will emit, (b) the lock level Postgres will take, (c) whether it forces a table rewrite, (d) severity given the snapshot's row counts. What's the threshold model — fixed row counts, estimated duration, or something better?
5. **Module boundaries** for `Cerbero.Snapshot`, `Cerbero.Catalog`, `Cerbero.Check`, `Cerbero.Migration.Parser`, and the two Mix tasks. Name what each owns and what it explicitly doesn't.
6. **The initial rule set** — the smallest set that demonstrably does something `excellent_migrations` structurally cannot. Quality over count. One rule that says _"this takes ACCESS EXCLUSIVE on a table with 412M estimated rows and will block reads for an estimated N minutes"_ is worth more than twenty rules that restate the existing linter.
7. **CI ergonomics.** Output formats (human, JSON, SARIF?), exit codes, baselining for existing violations, and the `@safety_assured`-equivalent escape hatch.
8. **The test strategy**, per the section above — taxonomy, fixtures, what needs real databases, and the first failing test you intend to write.
9. **Open questions and risks** you want the author to decide before code is written.

## Prior art — read it before proposing anything

- `excellent_migrations` (Elixir, MIT, AST-only) — the incumbent to differentiate from. Know its exact rule list.
- `strong_migrations` (Ruby) — PG-version-aware, timeout config, generates safe rewrites. The bar.
- Squawk, and Atlas's PG analyzers (PG301–PG311) — for rule taxonomy.
- Postgres lock level documentation — the mapping from DDL to lock mode is the technical heart of this tool and must be _correct_, not approximate.

For every rule you propose, state plainly whether it is (a) already covered free by `excellent_migrations`, or (b) impossible without the snapshot. Category (b) is the entire reason this project exists. If the plan comes out mostly (a), say so directly — that is a finding, not a failure, and the author would rather hear it now than after a year of evenings.

## Mandatory: adversarial review before any code

Once the plan is written, **do not implement it.** Spawn two independent review agents with the charters below. Give each the full plan and its charter, and _nothing else_ — in particular, do not tell either reviewer that the plan is yours, do not ask them to be constructive, and do not soften the charter. Their job is to find what's wrong, not to be agreeable. A reviewer that returns "looks good with minor nits" has failed its charter and should be re-run with the failure pointed out.

### Reviewer 1 — the hostile Postgres/Ecto domain expert

> You are a principal engineer who has personally caused a production outage with a schema migration, and who has spent years on Postgres internals and Ecto. You are reviewing a design that claims it can judge, offline and from a metadata snapshot, whether a migration is safe to run against a production database. You believe this claim is probably overconfident. Find every way it is wrong.
>
> Attack, at minimum: the DDL → lock-mode mapping (is it _correct_, including the cases where Postgres version changes the answer?); `reltuples` staleness and the fact that a snapshot is a lie the moment it is taken; whether estimated row counts can support any honest duration estimate; CockroachDB's catalog and locking semantics diverging from Postgres in ways the design has waved away; whether the privacy boundary actually holds (column defaults? check constraints? partial index predicates? — these can embed literal data); what happens with concurrent DDL, `lock_timeout`, and lock queues that a static rule cannot see; and every false-negative that would let a real outage through. False negatives are the failure mode that destroys the product's credibility — hunt those specifically.
>
> Rank your objections by severity. For each, state either a concrete remedy or "this is fatal to the approach as designed." Do not pad the list with style feedback.

### Reviewer 2 — the hostile product and scope adversary

> You are a skeptical engineering leader who has watched many developer tools die. You are reviewing the plan for an open-source Elixir tool. Your prior is that it is a linter with extra steps, that it duplicates free tools, and that nobody will actually adopt it. Make that case as strongly as the plan allows, and only concede where the plan genuinely defeats you.
>
> Attack, at minimum: the real overlap with `excellent_migrations`, Squawk, and Atlas's analyzers — rule by rule, not in the abstract; whether _anyone_ will actually get approval to run an exporter against production, and what happens to the entire product if the answer is no; whether teams will really commit a snapshot artifact to git and keep it fresh; whether the CockroachDB angle is a genuine differentiator or a niche within a niche; the adoption path when the incumbent is free, installed, and good enough; scope creep and YAGNI throughout the plan; and the possibility that this is a solution the author wants to _build_ rather than one anyone wants to _use_. Note that a prior attempt in this space (`pgroll_ex`) shipped in 2024 and got 143 downloads and zero dependents — argue for what that predicts.
>
> Rank your objections by severity. For each, state either a concrete remedy or "this should not be built." Do not pad the list with style feedback.

### Then: adjudicate, don't capitulate

Collect both reviews and respond to **every** objection explicitly, with one of:

- **Accept** — and revise the plan, showing what changed.
- **Reject** — with a stated reason. Reviewers are hostile by construction; some of their objections will be wrong, and cargo-culting all of them produces a worse plan than ignoring all of them. Defend the design where it deserves defending.
- **Escalate** — flag it for the author to decide, because it turns on information you don't have (their appetite for support load, whether their employer would approve a prod exporter, how big their tables really are).

Then output the revised plan, a short changelog of what the reviews changed, and the escalation list. Still no implementation code. The author reviews the revised plan before the first failing test is written.

## Definition of done for the spike

A user can run `mix cerbero.snapshot` against production, commit the artifact, and have `mix cerbero.check` fail CI with a message that a reviewer immediately understands and could not have gotten from any existing Elixir tool.

## The sequence, to be explicit

1. Ask me any clarifying questions that would change the design.
2. Write the plan.
3. Run both adversarial reviews.
4. Adjudicate every objection; produce the revised plan, changelog, and escalation list.
5. **Stop.** I review before the first failing test is written.

Start with step 1.
