defmodule Cerbero.Snapshot.Exporter do
  @moduledoc """
  Builds a raw snapshot map from a live connection (or a DBA-returned
  file). Session is read-only with a short statement_timeout — defense in
  depth, not the privacy mechanism (that is the Queries allowlist).

  CRDB row-count honesty: `crdb_internal.table_row_statistics.estimated_row_count`
  reads a literal `0` (not NULL) for a table with no propagated statistics
  yet — see `crdb_row_counts/2` and `Queries`'s moduledoc note for the
  full reasoning. A `0` is mapped to `nil` here, never forwarded as a real
  row count, so `Cerbero.Catalog.scale/2` reads it as unknown (unbounded),
  never a fabricated zero.
  """

  alias Cerbero.Snapshot.Bucketing
  alias Cerbero.Snapshot.Exporter.Queries

  @cerbero_version Mix.Project.config()[:version]

  @spec export(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export(url, opts \\ []) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    schemas = Keyword.get(opts, :schemas, ["public"])
    migration_source = Keyword.get(opts, :migration_source, "schema_migrations")
    precision = Keyword.get(opts, :precision, :exact)

    # Postgrex.start_link/1 has no :url option of its own (that's an
    # Ecto.Repo convenience) — parse it into the discrete opts (:hostname,
    # :port, :database, :username, :password) Postgrex actually expects.
    connect_opts =
      url
      |> Ecto.Repo.Supervisor.parse_url()
      |> Keyword.delete(:scheme)
      |> Keyword.put(:pool_size, 1)

    with {:ok, conn} <- Postgrex.start_link(connect_opts) do
      try do
        q!(conn, "SET default_transaction_read_only = on")
        q!(conn, "SET statement_timeout = '15s'")

        with {:ok, raw} <- build(conn, clock, schemas, migration_source) do
          {:ok, Bucketing.finalize(raw, precision)}
        end
      rescue
        e -> {:error, {:export_failed, Exception.message(e)}}
      after
        GenServer.stop(conn)
      end
    end
  end

  defp build(conn, clock, schemas, migration_source) do
    engine = detect_engine(conn)

    tables = rows(q!(conn, Queries.tables(engine["name"]), [schemas]))
    columns = rows(q!(conn, Queries.columns(), [schemas]))
    indexes = rows(q!(conn, Queries.indexes(engine["name"]), [schemas]))
    constraints = rows(q!(conn, Queries.constraints(), [schemas]))
    crdb_row_counts = crdb_row_counts(conn, engine["name"])

    applied =
      case q(conn, Queries.applied_migrations(quote_ident(migration_source))) do
        {:ok, result} -> result |> rows() |> Enum.map(&hd/1) |> Enum.sort()
        {:error, _} -> []
      end

    [[database]] = rows(q!(conn, Queries.current_database()))
    [[standby]] = rows(q!(conn, Queries.standby()))

    # PG's pg_stat_database always has exactly one row per database. CRDB
    # implements the view (queries against it don't error) but leaves it
    # empty — confirmed empirically in the layer 4 CRDB differential — so
    # the zero-row case needs an explicit default rather than assuming a
    # first row exists.
    stats_reset =
      conn |> q!(Queries.stats_reset()) |> rows() |> List.first([nil]) |> List.first()

    {:ok,
     %{
       "applied_migrations" => applied,
       "cerbero_version" => @cerbero_version,
       "checksum" => nil,
       "collected_at" => clock.() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
       "database" => database,
       "engine" => engine,
       "format_version" => Cerbero.Snapshot.format_version(),
       "standby" => standby,
       "stats_provenance" => if(standby, do: "standby", else: "primary"),
       "stats_reset" => stats_reset && DateTime.to_iso8601(stats_reset),
       "tables" => assemble_tables(tables, columns, indexes, constraints, crdb_row_counts)
     }}
  end

  # CRDB leaves pg_class.reltuples/relpages NULL and its pg_stat_user_tables
  # shim yields no n_live_tup either (confirmed empirically against a live
  # v25.1 node) — without this, every CRDB table's row scale would be
  # unknown, and `n_live_tup || 0` used to paper over that with a
  # fabricated zero (Catalog.scale then read it as {:rows, 0, 0}: every
  # scale rule silently passed). crdb_internal.table_row_statistics is the
  # engine's own row-count estimate (design §1); wiring it into n_live_tup
  # during assembly gives CRDB tables a real signal instead of a lie.
  #
  # CRDB limitation, confirmed empirically against a live v25.1 node:
  # `estimated_row_count` is NOT NULL-until-collected the way it first
  # appears — it reads a literal `0` for a table with no propagated
  # statistics, indistinguishable from a genuinely empty table, and this
  # persisted for several seconds after `CREATE STATISTICS` completed
  # (some internal cache/propagation lag beyond the statement's own
  # commit). A `0` here is therefore treated the same as "no signal" —
  # mapped to nil, not forwarded as a real zero — so a fresh CRDB table
  # with real rows never exports a fabricated `n_live_tup: 0` while its
  # statistics are still catching up. The cost: a *genuinely* empty CRDB
  # table also reads as unknown-scale (noisy — Catalog treats it as
  # unbounded) rather than confidently zero. That is the design's stated
  # direction ("unknown scale = unbounded, never small") — noisy but safe
  # beats confidently wrong.
  # Keyed by bare table name (the view has no schema column); a
  # same-named table in two configured schemas could collide, an accepted
  # limitation for a spike whose default (and typical) config is a single
  # schema.
  defp crdb_row_counts(conn, "cockroachdb") do
    conn
    |> q!(Queries.crdb_row_counts())
    |> rows()
    |> Map.new(fn
      [name, 0] -> {name, nil}
      [name, count] -> {name, count}
    end)
  end

  defp crdb_row_counts(_conn, _postgres), do: %{}

  defp detect_engine(conn) do
    [[probe]] = rows(q!(conn, Queries.crdb_probe()))

    if probe > 0 do
      [[version]] = rows(q!(conn, Queries.crdb_version()))
      %{"name" => "cockroachdb", "version" => version, "version_num" => crdb_version_num(version)}
    else
      [[num]] = rows(q!(conn, Queries.server_version_num()))

      %{
        "name" => "postgres",
        "version" => "#{div(num, 10_000)}.#{rem(num, 10_000)}",
        "version_num" => num
      }
    end
  end

  # "v25.1.2" -> 25_102 (major*1000 + minor*100 + patch, best-effort)
  defp crdb_version_num(version) do
    case Regex.run(~r/v?(\d+)\.(\d+)(?:\.(\d+))?/, version) do
      [_, major, minor, patch] ->
        String.to_integer(major) * 1000 + String.to_integer(minor) * 100 +
          String.to_integer(patch)

      [_, major, minor] ->
        String.to_integer(major) * 1000 + String.to_integer(minor) * 100

      _ ->
        0
    end
  end

  defp assemble_tables(tables, columns, indexes, constraints, crdb_row_counts \\ %{}) do
    col_by = Enum.group_by(columns, fn [schema, table | _] -> {schema, table} end)
    idx_by = Enum.group_by(indexes, fn [schema, table | _] -> {schema, table} end)
    con_by = Enum.group_by(constraints, fn [schema, table | _] -> {schema, table} end)

    Enum.map(tables, fn [
                          schema,
                          name,
                          partitioned,
                          partition_of,
                          reltuples,
                          relpages,
                          n_live_tup,
                          last_analyze,
                          last_autoanalyze,
                          seq_scan,
                          idx_scan,
                          n_tup_ins,
                          n_tup_upd,
                          n_tup_del,
                          heap_bytes,
                          total_bytes
                        ] ->
      %{
        "schema" => schema,
        "name" => name,
        "partitioned" => partitioned,
        "partition_of" => partition_of,
        # PG's pg_class.reltuples/relpages are NOT NULL (0 by default,
        # never nil). CockroachDB's pg_class shim leaves both NULL —
        # confirmed empirically in the layer 4 CRDB differential — so
        # `reltuples * 1.0` must not assume a number is there; nil stays
        # nil (an honest "unknown"), same as heap_bytes/total_bytes below.
        "reltuples" => reltuples && reltuples * 1.0,
        "relpages" => relpages,
        # Same honesty rule as reltuples above: prefer the engine's own
        # activity-stats count, fall back to CRDB's row-statistics estimate
        # (map lookup on a table without stats yields nil too), and NEVER
        # coerce a true "the engine gave no signal" into 0 — Catalog.scale
        # treats nil/nil as :unknown, not zero (see Catalog.row_estimate).
        "n_live_tup" => n_live_tup || Map.get(crdb_row_counts, name),
        "last_analyze" => iso(last_analyze),
        "last_autoanalyze" => iso(last_autoanalyze),
        "seq_scan" => seq_scan || 0,
        "idx_scan" => idx_scan || 0,
        "n_tup_ins" => n_tup_ins || 0,
        "n_tup_upd" => n_tup_upd || 0,
        "n_tup_del" => n_tup_del || 0,
        "heap_bytes" => heap_bytes,
        "total_bytes" => total_bytes,
        "columns" => Enum.map(Map.get(col_by, {schema, name}, []), &column_json/1),
        "indexes" => Enum.map(Map.get(idx_by, {schema, name}, []), &index_json/1),
        "constraints" => Enum.map(Map.get(con_by, {schema, name}, []), &constraint_json/1)
      }
    end)
  end

  defp column_json([
         _s,
         _t,
         name,
         type,
         not_null,
         identity,
         generated_stored,
         has_default,
         default_kind
       ]) do
    %{
      "name" => name,
      "type" => type,
      "not_null" => not_null,
      "identity" => identity,
      "generated" => if(generated_stored, do: "stored"),
      "default" =>
        if has_default do
          %{
            "present" => true,
            "volatile" => default_volatile?(default_kind),
            "kind" => default_kind
          }
        end
    }
  end

  # See Queries moduledoc: volatile is derived from kind, not read from the
  # catalog directly. "literal" is provably a constant; "sequence" and
  # "expression" both cannot be, so both count as volatile — biased toward
  # over-reporting (a deterministic expression default reads as volatile
  # too) rather than under-reporting (missing a real rewrite risk).
  defp default_volatile?("literal"), do: false
  defp default_volatile?(_kind), do: true

  defp index_json([_s, _t, name, unique, primary, valid, method, partial, bytes, key_names]) do
    %{
      "name" => name,
      "unique" => unique,
      "primary" => primary,
      "valid" => valid,
      "method" => method,
      "partial" => partial,
      "bytes" => bytes,
      "keys" =>
        Enum.map(key_names || [], fn
          nil -> %{"kind" => "expression"}
          col -> %{"kind" => "column", "name" => col}
        end)
    }
  end

  defp constraint_json([
         _s,
         _t,
         name,
         type,
         columns,
         validated,
         ref_table,
         ref_columns,
         on_delete,
         on_update,
         is_nn
       ]) do
    %{
      "name" => name,
      "type" => type,
      "columns" => columns || [],
      "validated" => validated,
      "references" => if(ref_table, do: %{"table" => ref_table, "columns" => ref_columns || []}),
      "on_delete" => if(type == "foreign_key", do: on_delete),
      "on_update" => if(type == "foreign_key", do: on_update),
      "is_not_null_check_on" => is_nn
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso(%NaiveDateTime{} = ndt), do: ndt |> DateTime.from_naive!("Etc/UTC") |> iso()

  defp q(conn, sql, params \\ []), do: Postgrex.query(conn, sql, params)
  defp q!(conn, sql, params \\ []), do: Postgrex.query!(conn, sql, params)
  defp rows(%Postgrex.Result{rows: rows}), do: rows

  defp quote_ident(name), do: ~s|"#{String.replace(name, ~s|"|, ~s|""|)}"|

  # --- DBA path ------------------------------------------------------------

  @doc "A psql script: each query wrapped so output is JSON-lines per section."
  @spec emit_sql() :: String.t()
  def emit_sql do
    Queries.emit_list()
    |> Enum.map_join("\n", fn {name, sql} ->
      one_line = sql |> String.trim() |> String.trim_trailing(";")

      """
      \\echo -- cerbero:begin:#{name}
      COPY (SELECT row_to_json(q) FROM (#{one_line}) q) TO STDOUT;
      \\echo -- cerbero:end:#{name}
      """
    end)
  end

  @doc "Rebuild a raw snapshot map from the DBA-returned psql output."
  @spec from_file(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def from_file(path, opts \\ []) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    precision = Keyword.get(opts, :precision, :exact)

    with {:ok, contents} <- File.read(path),
         {:ok, raw} <- build_from_sections(parse_sections(contents), clock) do
      {:ok, Bucketing.finalize(raw, precision)}
    end
  end

  defp parse_sections(contents) do
    contents
    |> String.split("\n")
    |> Enum.reduce({nil, %{}}, fn line, {current, acc} ->
      case line do
        "-- cerbero:begin:" <> name ->
          {name, Map.put(acc, name, [])}

        "-- cerbero:end:" <> _ ->
          {nil, acc}

        "" ->
          {current, acc}

        json when current != nil ->
          {current, Map.update!(acc, current, &(&1 ++ [JSON.decode!(json)]))}

        _ ->
          {current, acc}
      end
    end)
    |> elem(1)
  end

  # Maps each section's JSON rows through the same assemble path as the
  # live exporter. Each row lands as a JSON object keyed by the SELECT
  # list's column aliases (per Queries), so we pluck by key into the
  # positional row lists assemble_tables/columns/indexes/constraints
  # expect, then reuse build/4's assembly code verbatim. Scalar sections
  # (single column, possibly no alias) are read by value instead of by
  # key, since the auto-derived JSON key for an unaliased expression is
  # an implementation detail of the server's column-naming rules, not
  # part of this contract. PG only in v1 (CRDB DBA path is via the mix
  # task against a live connection).
  defp build_from_sections(sections, clock) do
    server_version_num = scalar(sections["server_version_num"])
    database = scalar(sections["current_database"])
    standby = scalar(sections["standby"])
    stats_reset = sections["stats_reset"] |> scalar() |> parse_ts()

    engine = %{
      "name" => "postgres",
      "version" => "#{div(server_version_num, 10_000)}.#{rem(server_version_num, 10_000)}",
      "version_num" => server_version_num
    }

    tables = Enum.map(sections["tables"] || [], &table_row/1)
    columns = Enum.map(sections["columns"] || [], &column_row/1)
    indexes = Enum.map(sections["indexes"] || [], &index_row/1)
    constraints = Enum.map(sections["constraints"] || [], &constraint_row/1)

    applied =
      (sections["applied_migrations"] || [])
      |> Enum.map(&scalar_row/1)
      |> Enum.sort()

    {:ok,
     %{
       "applied_migrations" => applied,
       "cerbero_version" => @cerbero_version,
       "checksum" => nil,
       "collected_at" => clock.() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
       "database" => database,
       "engine" => engine,
       "format_version" => Cerbero.Snapshot.format_version(),
       "standby" => standby,
       "stats_provenance" => if(standby, do: "standby", else: "primary"),
       "stats_reset" => stats_reset && DateTime.to_iso8601(stats_reset),
       "tables" => assemble_tables(tables, columns, indexes, constraints)
     }}
  end

  # A one-row, one-column section (e.g. `SELECT version()`): read the
  # sole value regardless of the auto-derived JSON key.
  defp scalar([row]) when is_map(row), do: scalar_row(row)
  defp scalar(_), do: nil

  defp scalar_row(row) when is_map(row), do: row |> Map.values() |> List.first()

  defp table_row(m) do
    [
      m["schema"],
      m["name"],
      m["partitioned"],
      m["partition_of"],
      m["reltuples"],
      m["relpages"],
      m["n_live_tup"],
      parse_ts(m["last_analyze"]),
      parse_ts(m["last_autoanalyze"]),
      m["seq_scan"],
      m["idx_scan"],
      m["n_tup_ins"],
      m["n_tup_upd"],
      m["n_tup_del"],
      m["heap_bytes"],
      m["total_bytes"]
    ]
  end

  defp column_row(m) do
    [
      m["schema"],
      m["table"],
      m["name"],
      m["type"],
      m["not_null"],
      m["identity"],
      m["generated_stored"],
      m["has_default"],
      m["default_kind"]
    ]
  end

  defp index_row(m) do
    [
      m["schema"],
      m["table"],
      m["name"],
      m["unique"],
      m["primary"],
      m["valid"],
      m["method"],
      m["partial"],
      m["bytes"],
      m["key_names"]
    ]
  end

  defp constraint_row(m) do
    [
      m["schema"],
      m["table"],
      m["name"],
      m["type"],
      m["columns"],
      m["validated"],
      m["ref_table"],
      m["ref_columns"],
      m["on_delete"],
      m["on_update"],
      m["is_not_null_check_on"]
    ]
  end

  # Parses the ISO-8601 text row_to_json produces for a timestamp(tz)
  # column back into a %DateTime{} with the same microsecond precision
  # Postgrex's binary-protocol decoder uses, so downstream `iso/1` (and
  # the round-trip identity test) see identical values either way.
  defp parse_ts(nil), do: nil

  defp parse_ts(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} -> %{dt | microsecond: {elem(dt.microsecond, 0), 6}}
      {:error, _} -> naive_parse_ts(text)
    end
  end

  defp naive_parse_ts(text) do
    case NaiveDateTime.from_iso8601(text) do
      {:ok, ndt} ->
        ndt
        |> DateTime.from_naive!("Etc/UTC")
        |> then(&%{&1 | microsecond: {elem(&1.microsecond, 0), 6}})

      {:error, reason} ->
        raise ArgumentError, "cannot parse timestamp #{inspect(text)}: #{inspect(reason)}"
    end
  end
end
