defmodule Cerbero.Snapshot.Exporter.Queries do
  @moduledoc """
  EVERY SQL statement the exporter can run, on one reviewable screen.
  No dynamic SQL beyond schema-name parameters and the quoted
  migrations-table identifier. The only non-catalog read is the versions
  column of the migrations table. This module is the privacy allowlist's
  first layer — review it like one.
  """

  def version, do: "SELECT version()"
  def server_version_num, do: "SELECT current_setting('server_version_num')::int"
  def current_database, do: "SELECT current_database()"
  def standby, do: "SELECT pg_is_in_recovery()"

  def stats_reset,
    do: "SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()"

  def crdb_probe,
    do: "SELECT count(*) FROM information_schema.schemata WHERE schema_name = 'crdb_internal'"

  # sole non-catalog read; identifier is quote_ident-ed in code
  def applied_migrations(quoted_table), do: "SELECT version::text FROM #{quoted_table} ORDER BY 1"

  def tables,
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
           ad.oid IS NOT NULL AS has_default,
           CASE WHEN ad.oid IS NULL THEN NULL
                WHEN pg_get_expr(ad.adbin, ad.adrelid) LIKE 'nextval(%' THEN 'sequence'
                WHEN pg_get_expr(ad.adbin, ad.adrelid) ~ '^[^(]*$' THEN 'literal'
                ELSE 'expression' END AS default_kind,
           -- "volatile" here means "not a literal/sequence, so not provably
           -- safe" — the same call a DSL-only default: {:fragment, _} makes
           -- offline. It is NOT pg_proc.provolatile: Postgres never records
           -- a pg_depend row from a default onto a pinned (built-in)
           -- function, so now()/clock_timestamp()/random() are invisible to
           -- that join and it under-reports almost everything real
           -- migrations use. Same syntactic test as default_kind instead.
           CASE WHEN ad.oid IS NULL THEN false
                WHEN pg_get_expr(ad.adbin, ad.adrelid) LIKE 'nextval(%' THEN false
                WHEN pg_get_expr(ad.adbin, ad.adrelid) ~ '^[^(]*$' THEN false
                ELSE true END AS default_volatile
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
    WHERE c.relkind IN ('r', 'p') AND n.nspname = ANY($1)
      AND a.attnum > 0 AND NOT a.attisdropped
    ORDER BY n.nspname, c.relname, a.attnum
    """

  def indexes,
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
                THEN (regexp_match(pg_get_constraintdef(con.oid), '\\(([a-z0-9_]+) IS NOT NULL',  'i'))[1]
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

  def crdb_row_counts,
    do: "SELECT table_name, estimated_row_count FROM crdb_internal.table_row_statistics"

  @doc "All (name, sql) pairs the --emit-sql script includes, in order."
  def emit_list do
    [
      {"version", version()},
      {"server_version_num", server_version_num()},
      {"current_database", current_database()},
      {"standby", standby()},
      {"stats_reset", stats_reset()},
      {"tables", String.replace(tables(), "ANY($1)", "ANY(ARRAY['public'])")},
      {"columns", String.replace(columns(), "ANY($1)", "ANY(ARRAY['public'])")},
      {"indexes", String.replace(indexes(), "ANY($1)", "ANY(ARRAY['public'])")},
      {"constraints", String.replace(constraints(), "ANY($1)", "ANY(ARRAY['public'])")},
      {"applied_migrations", applied_migrations("schema_migrations")}
    ]
  end
end
