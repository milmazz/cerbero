# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | ✅        |

## Reporting a vulnerability

Please report security issues **privately** — do not open a public GitHub
issue. Use GitHub's private vulnerability reporting on
<https://github.com/milmazz/cerbero/security/advisories/new>. You should
receive an acknowledgment within a few days. Please include a minimal
reproduction where possible.

Coordinated disclosure is appreciated: give us a reasonable window to ship a
fix before publishing details.

## What counts as a vulnerability here

Cerbero's security posture centers on its **privacy boundary**. The snapshot
artifact is designed to contain only identifiers, type names, enumerated
keywords, booleans, numbers, and timestamps — never expression text, never
literals, never row data. In particular, the following are security bugs and
we want to hear about them privately:

- Any code path through which `mix cerbero.snapshot` (live or via
  `--emit-sql` / `--from-file`) can export expression text, SQL literals,
  statistics values (`pg_stats` histograms/MCVs), or row data into the
  snapshot artifact.
- Any SQL executed by the exporter that is not present in
  `Cerbero.Snapshot.Exporter.Queries`, or any injection vector through the
  schema-name parameters or the migrations-table identifier.
- The exporter's read-only session guarantees being bypassable (the session
  sets `default_transaction_read_only = on`; queries are the allowlist —
  defense in depth, but a write path is still a bug).
- Code execution during checking: `mix cerbero.check` performs static AST
  analysis and must never execute user migration code. Any input that causes
  evaluation of migration source is a vulnerability.
- Crafted snapshot or migration files causing more than a clean error
  (exit 2) — e.g., code execution or resource exhaustion during decode.

## What is *not* a vulnerability

- Table and column names appearing in the snapshot — they are schema
  metadata and already appear in the repository's own migration files. This
  is documented behavior.
- Row counts and byte sizes appearing in the snapshot — these are business
  metrics by nature and their presence is documented; teams who need to can
  bucket them once `precision: :order_of_magnitude` ships.
- The snapshot checksum being regenerable by anyone who can commit — it is
  documented as corruption/hand-edit detection, not tamper-proofing.
- False negatives in migration safety checks. Cerbero explicitly does not
  certify migrations as safe; missed unsafe patterns are ordinary bugs
  (please do report them — publicly is fine).

## Note on `.cerbero.exs`

Cerbero evaluates `.cerbero.exs` as Elixir code, like `mix.exs` and
`config/*.exs`. It is repository-local configuration and carries the same
trust level as the rest of the repository's build code. Do not run cerbero
against repositories you do not trust.
