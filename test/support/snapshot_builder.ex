defmodule Cerbero.Test.SnapshotBuilder do
  @moduledoc """
  Builds raw snapshot maps for tests, stamped through the real checksum
  path so every fixture a rule test consumes has passed the same strict
  decode + privacy allowlist as a production snapshot.
  """

  alias Cerbero.Snapshot

  def build(overrides \\ %{}) do
    %{
      "applied_migrations" => [],
      "cerbero_version" => "0.1.0",
      "checksum" => nil,
      "collected_at" => "2026-07-01T00:00:00Z",
      "database" => "app_prod",
      "engine" => %{"name" => "postgres", "version" => "15.4", "version_num" => 150_004},
      "format_version" => 1,
      "standby" => false,
      "stats_provenance" => "primary",
      "stats_reset" => "2026-01-01T00:00:00Z",
      "tables" => []
    }
    |> Map.merge(overrides)
    |> Snapshot.stamp()
  end

  def build_snapshot(overrides \\ %{}) do
    {:ok, snapshot} = Snapshot.decode(build(overrides))
    snapshot
  end

  @doc "A table map with sane small defaults; override what the test cares about."
  def table(name, overrides \\ %{}) do
    %{
      "columns" => [column("id", %{"type" => "bigint"})],
      "constraints" => [],
      "heap_bytes" => 8192,
      "idx_scan" => 0,
      "indexes" => [],
      "last_analyze" => nil,
      "last_autoanalyze" => "2026-06-30T00:00:00Z",
      "n_live_tup" => 100,
      "n_tup_del" => 0,
      "n_tup_ins" => 0,
      "n_tup_upd" => 0,
      "name" => name,
      "partition_of" => nil,
      "partitioned" => false,
      "relpages" => 1,
      "reltuples" => 100.0,
      "schema" => "public",
      "seq_scan" => 0,
      "total_bytes" => 8192
    }
    |> Map.merge(overrides)
  end

  def column(name, overrides \\ %{}) do
    %{
      "default" => nil,
      "generated" => nil,
      "identity" => false,
      "name" => name,
      "not_null" => false,
      "type" => "bigint"
    }
    |> Map.merge(overrides)
  end

  def index(name, keys, overrides \\ %{}) do
    %{
      "bytes" => 8192,
      "keys" => Enum.map(keys, &%{"kind" => "column", "name" => &1}),
      "method" => "btree",
      "name" => name,
      "partial" => false,
      "primary" => false,
      "unique" => false,
      "valid" => true
    }
    |> Map.merge(overrides)
  end

  def fk(name, columns, ref_table, overrides \\ %{}) do
    %{
      "columns" => columns,
      "is_not_null_check_on" => nil,
      "name" => name,
      "on_delete" => "no_action",
      "on_update" => "no_action",
      "references" => %{"columns" => ["id"], "table" => ref_table},
      "type" => "foreign_key",
      "validated" => true
    }
    |> Map.merge(overrides)
  end
end
