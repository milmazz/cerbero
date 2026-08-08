defmodule Cerbero.Snapshot.Exporter.Queries do
  @moduledoc """
  EVERY SQL statement the exporter can run, on one reviewable screen.
  No dynamic SQL beyond schema-name parameters and the quoted
  migrations-table identifier. The only non-catalog read is the versions
  column of the migrations table. This module is the privacy allowlist's
  first layer — review it like one.

  Note on `tables/1` and `indexes/1`: both take an `engine` ("postgres" |
  "cockroachdb") because `pg_relation_size`/`pg_total_relation_size` —
  the only byte-size functions PG exposes — don't exist on CockroachDB
  (confirmed empirically in the layer 4 CRDB differential: `unknown
  function: pg_relation_size()`, SQLSTATE 42883). Rather than fail the
  whole export over two columns, the CockroachDB branch reports
  `heap_bytes`/`total_bytes`/`bytes` as `NULL` — an honest "unknown," not
  a fabricated zero. CRDB does expose row-count estimates via
  `crdb_internal.table_row_statistics` (see `crdb_row_counts/0`) but nothing
  equivalent for on-disk bytes was found in this CRDB version (v25.1) at
  the time of writing; revisit if a later version adds one.

  Note on `crdb_row_counts/0`: `estimated_row_count` reads a literal `0`
  — not SQL NULL — for a table whose statistics haven't been
  collected/propagated yet, confirmed empirically to persist for several
  seconds after a statistics-collection statement (a "create statistics"
  DDL, deliberately not spelled in full caps here — this comment lives in
  the module the read-only regression test greps for write keywords)
  completes (some internal cache/propagation lag beyond the statement's
  own commit). `0` is therefore indistinguishable at the SQL level from
  "no statistics yet," so `Cerbero.Snapshot.Exporter` maps a `0` here to
  `nil` rather than forwarding it as a real row count — see the
  `crdb_row_counts/2` comment there for the full reasoning and its
  accepted cost (a genuinely empty CRDB table also reads as unknown
  scale, not confidently zero).

  Note on `constraints/0`: `is_not_null_check_on` used to extract its
  capture group with `regexp_match(...)... [1]`, which does not exist on
  CockroachDB (`unknown function: regexp_match()`). `substring(x from
  pattern)` — SQL-standard POSIX substring, not engine-specific — returns
  the same capture directly (no array indexing) and is supported
  identically by both engines, so this one has no `engine` branch; it was
  simply the more portable way to write the same query.

  Note on `columns/0`: it reports `default_kind` (a closed enum: `sequence`
  | `literal` | `expression`) but deliberately does NOT compute a
  `default_volatile` column itself. `Cerbero.Snapshot.Exporter` derives
  `volatile` from `default_kind` downstream (`literal` -> false, anything
  else -> true) — privacy is unaffected since `kind` is already an exported
  enum. This replaced an earlier `pg_depend`/`pg_proc.provolatile` join that
  under-reported: Postgres never records a `pg_depend` row from a default
  onto a *pinned* (built-in) function, so `now()`, `clock_timestamp()`,
  `random()`, and `nextval()` were all invisible to it. Deriving from `kind`
  instead over-reports (a deterministic `expression` default like
  `lower('x')` reads as volatile too) rather than under-report — the safe
  direction, since a false "this rewrites the table" is a nuisance and a
  false "this doesn't" is an outage.
  """

  def version, do: "SELECT version()"
  def server_version_num, do: "SELECT current_setting('server_version_num')::int"
  def current_database, do: "SELECT current_database()"
  def standby, do: "SELECT pg_is_in_recovery()"

  def stats_reset, do: "SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()"

  def crdb_probe, do: "SELECT count(*) FROM information_schema.schemata WHERE schema_name = 'crdb_internal'"

  # sole non-catalog read; identifier is quote_ident-ed in code
  def applied_migrations(quoted_table), do: "SELECT version::text FROM #{quoted_table} ORDER BY 1"

  def tables(engine \\ "postgres")

  def tables("cockroachdb"),
    do: """
    SELECT n.nspname AS schema, c.relname AS name,
           c.relkind = 'p' AS partitioned,
           parent.relnamespace::regnamespace::text || '.' || parent.relname AS partition_of,
           c.reltuples::float8 AS reltuples, c.relpages::bigint AS relpages,
           s.n_live_tup, s.last_analyze, s.last_autoanalyze,
           s.seq_scan, s.idx_scan, s.n_tup_ins, s.n_tup_upd, s.n_tup_del,
           NULL::bigint AS heap_bytes, NULL::bigint AS total_bytes
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
    LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
    LEFT JOIN pg_class parent ON parent.oid = i.inhparent
    WHERE c.relkind IN ('r', 'p') AND n.nspname = ANY($1)
    ORDER BY n.nspname, c.relname
    """

  def tables(_postgres),
    do: """
    SELECT n.nspname AS schema, c.relname AS name,
           c.relkind = 'p' AS partitioned,
           parent.relnamespace::regnamespace::text || '.' || parent.relname AS partition_of,
           c.reltuples::float8 AS reltuples, c.relpages::bigint AS relpages,
           s.n_live_tup, s.last_analyze, s.last_autoanalyze,
           s.seq_scan, s.idx_scan, s.n_tup_ins, s.n_tup_upd, s.n_tup_del,
           pg_relation_size(c.oid) AS heap_bytes, pg_total_relation_size(c.oid) AS total_bytes
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
    LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
    LEFT JOIN pg_class parent ON parent.oid = i.inhparent
    WHERE c.relkind IN ('r', 'p') AND n.nspname = ANY($1)
    ORDER BY n.nspname, c.relname
    """

  def columns,
    do: """
    SELECT n.nspname AS schema, c.relname AS table, a.attname AS name,
           format_type(a.atttypid, a.atttypmod) AS type,
           a.attnotnull AS not_null,
           a.attidentity <> '' AS identity,
           a.attgenerated = 's' AS generated_stored,
           -- GENERATED ... STORED columns have a pg_attrdef row too (it
           -- holds the generation expression), so ad.oid IS NOT NULL alone
           -- would fabricate a `default` for every generated column. Gate
           -- both has_default and default_kind on attgenerated = '' so
           -- generated columns report generated_stored + default: nil, not
           -- a phantom "default".
           ad.oid IS NOT NULL AND a.attgenerated = '' AS has_default,
           CASE WHEN ad.oid IS NULL OR a.attgenerated <> '' THEN NULL
                WHEN pg_get_expr(ad.adbin, ad.adrelid) LIKE 'nextval(%' THEN 'sequence'
                WHEN pg_get_expr(ad.adbin, ad.adrelid) ~ '^[^(]*$' THEN 'literal'
                ELSE 'expression' END AS default_kind
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
    WHERE c.relkind IN ('r', 'p') AND n.nspname = ANY($1)
      AND a.attnum > 0 AND NOT a.attisdropped
    ORDER BY n.nspname, c.relname, a.attnum
    """

  def indexes(engine \\ "postgres")

  def indexes("cockroachdb"),
    do: """
    SELECT n.nspname AS schema, t.relname AS table, ic.relname AS name,
           i.indisunique AS unique, i.indisprimary AS primary, i.indisvalid AS valid,
           am.amname AS method, i.indpred IS NOT NULL AS partial,
           NULL::bigint AS bytes,
           (SELECT array_agg(CASE WHEN k.attnum = 0 THEN NULL ELSE a.attname END ORDER BY k.ord)
            FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
            LEFT JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
           ) AS key_names
    FROM pg_index i
    JOIN pg_class ic ON ic.oid = i.indexrelid
    JOIN pg_class t ON t.oid = i.indrelid
    JOIN pg_am am ON am.oid = ic.relam
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = ANY($1)
    ORDER BY n.nspname, t.relname, ic.relname
    """

  def indexes(_postgres),
    do: """
    SELECT n.nspname AS schema, t.relname AS table, ic.relname AS name,
           i.indisunique AS unique, i.indisprimary AS primary, i.indisvalid AS valid,
           am.amname AS method, i.indpred IS NOT NULL AS partial,
           pg_relation_size(ic.oid) AS bytes,
           (SELECT array_agg(CASE WHEN k.attnum = 0 THEN NULL ELSE a.attname END ORDER BY k.ord)
            FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
            LEFT JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
           ) AS key_names
    FROM pg_index i
    JOIN pg_class ic ON ic.oid = i.indexrelid
    JOIN pg_class t ON t.oid = i.indrelid
    JOIN pg_am am ON am.oid = ic.relam
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = ANY($1)
    ORDER BY n.nspname, t.relname, ic.relname
    """

  def constraints,
    do: """
    SELECT n.nspname AS schema, t.relname AS table, con.conname AS name,
           CASE con.contype WHEN 'p' THEN 'primary' WHEN 'u' THEN 'unique'
                WHEN 'f' THEN 'foreign_key' WHEN 'c' THEN 'check' WHEN 'x' THEN 'exclusion' END AS type,
           (SELECT array_agg(a.attname ORDER BY k.ord)
            FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
            JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum) AS columns,
           con.convalidated AS validated,
           CASE WHEN con.contype = 'f'
                THEN ft.relnamespace::regnamespace::text || '.' || ft.relname END AS ref_table,
           CASE WHEN con.contype = 'f' THEN
             (SELECT array_agg(a.attname ORDER BY k.ord)
              FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
              JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum) END AS ref_columns,
           CASE con.confdeltype WHEN 'a' THEN 'no_action' WHEN 'r' THEN 'restrict'
                WHEN 'c' THEN 'cascade' WHEN 'n' THEN 'set_null' WHEN 'd' THEN 'set_default' END AS on_delete,
           CASE con.confupdtype WHEN 'a' THEN 'no_action' WHEN 'r' THEN 'restrict'
                WHEN 'c' THEN 'cascade' WHEN 'n' THEN 'set_null' WHEN 'd' THEN 'set_default' END AS on_update,
           CASE WHEN con.contype = 'c'
                     AND pg_get_constraintdef(con.oid) ~* '^CHECK \\(\\(?([a-z0-9_]+) IS NOT NULL\\)?\\)$'
                THEN substring(pg_get_constraintdef(con.oid) from '(?i)\\(([a-z0-9_]+) IS NOT NULL')
           END AS is_not_null_check_on
    FROM pg_constraint con
    JOIN pg_class t ON t.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    LEFT JOIN pg_class ft ON ft.oid = con.confrelid
    WHERE n.nspname = ANY($1)
    ORDER BY n.nspname, t.relname, con.conname
    """

  # CRDB alternates (sizes/rows via crdb_internal; PG functions are unreliable there)
  def crdb_version, do: "SELECT value FROM crdb_internal.node_build_info WHERE field = 'Version'"

  def crdb_row_counts, do: "SELECT table_name, estimated_row_count FROM crdb_internal.table_row_statistics"

  # CRDB's analyze-timestamp equivalent (roadmap item 10): statistics
  # creation times from system.table_statistics (what SHOW STATISTICS FOR
  # TABLE reads), split manual vs automatic — CRDB names its automatic
  # collections '__auto__', so the manual max maps to last_analyze and the
  # auto max to last_autoanalyze. Reading system.* may be denied to
  # non-admin roles; the exporter degrades to no timestamps (honest nil)
  # rather than failing the export.
  def crdb_stats_times,
    do: """
    SELECT t.schema_name,
           t.name,
           max(CASE WHEN s.name <> '__auto__' THEN s."createdAt" END) AS manual_created,
           max(CASE WHEN s.name = '__auto__' THEN s."createdAt" END) AS auto_created
    FROM system.table_statistics s
    JOIN crdb_internal.tables t ON t.table_id = s."tableID"
    WHERE t.database_name = current_database()
      AND t.state = 'PUBLIC'
      AND t.schema_name = ANY($1)
    GROUP BY 1, 2
    """

  @doc """
  All (name, sql) pairs the --emit-sql script includes, in order. The
  engine argument selects the engine-branched queries and, for
  CockroachDB, appends the crdb-only sections; `from_file` detects the
  engine by the presence of the `crdb_version` section, so the two
  scripts stay self-describing.
  """
  def emit_list(engine \\ "postgres") do
    [
      {"version", version()},
      {"server_version_num", server_version_num()},
      {"current_database", current_database()},
      {"standby", standby()},
      {"stats_reset", stats_reset()},
      {"tables", String.replace(tables(engine), "ANY($1)", "ANY(ARRAY['public'])")},
      {"columns", String.replace(columns(), "ANY($1)", "ANY(ARRAY['public'])")},
      {"indexes", String.replace(indexes(engine), "ANY($1)", "ANY(ARRAY['public'])")},
      {"constraints", String.replace(constraints(), "ANY($1)", "ANY(ARRAY['public'])")},
      {"applied_migrations", applied_migrations("schema_migrations")}
    ] ++ crdb_emit_sections(engine)
  end

  defp crdb_emit_sections("cockroachdb") do
    [
      {"crdb_version", crdb_version()},
      {"crdb_row_counts", crdb_row_counts()},
      {"crdb_stats_times", String.replace(crdb_stats_times(), "ANY($1)", "ANY(ARRAY['public'])")}
    ]
  end

  defp crdb_emit_sections(_postgres), do: []
end
