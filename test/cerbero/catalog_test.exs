defmodule Cerbero.CatalogTest do
  use ExUnit.Case, async: true

  import Cerbero.Test.SnapshotBuilder

  alias Cerbero.Catalog
  alias Cerbero.Config
  alias Cerbero.Operation, as: Op
  alias Cerbero.Snapshot.Staleness
  alias Cerbero.SQL.Classifier.Classified

  defp catalog(tables, snapshot_overrides \\ %{}, staleness_overrides \\ []) do
    snapshot = build_snapshot(Map.merge(%{"tables" => tables}, snapshot_overrides))

    staleness =
      struct!(
        %Staleness{age_days: 1, scale_mode: :exact, threshold_multiplier: 1.0},
        staleness_overrides
      )

    Catalog.from_snapshot(snapshot, staleness)
  end

  setup do
    {:ok, config} = Config.load("nonexistent")
    %{config: config}
  end

  test "scale: max(reltuples, n_live_tup); bytes from heap_bytes" do
    cat =
      catalog([
        table("events", %{"reltuples" => 400.0, "n_live_tup" => 500, "heap_bytes" => 9000})
      ])

    assert Catalog.scale(cat, "events") == {:rows, 500, 9000}
  end

  test "scale: reltuples -1 (never analyzed, PG >= 14) falls back to n_live_tup" do
    cat = catalog([table("events", %{"reltuples" => -1.0, "n_live_tup" => 123})])
    assert {:rows, 123, _} = Catalog.scale(cat, "events")
  end

  test "partitioned parent: sum over partitions, never the parent row" do
    cat =
      catalog([
        table("events", %{
          "partitioned" => true,
          "reltuples" => 0.0,
          "n_live_tup" => 0,
          "heap_bytes" => 0
        }),
        table("events_p0", %{
          "partition_of" => "public.events",
          "n_live_tup" => 100,
          "reltuples" => 100.0,
          "heap_bytes" => 10
        }),
        table("events_p1", %{
          "partition_of" => "public.events",
          "n_live_tup" => 250,
          "reltuples" => 250.0,
          "heap_bytes" => 20
        })
      ])

    assert Catalog.scale(cat, "events") == {:rows, 350, 30}
  end

  test "unknown table is :unknown — absence is never safety", %{config: _} do
    cat = catalog([])
    assert Catalog.scale(cat, "ghost") == :unknown
    refute Catalog.known?(cat, "ghost")
  end

  test "reltuples AND n_live_tup both nil (CRDB gave no signal): scale is :unknown, never zero" do
    # This is exactly what a CRDB table with no collected row statistics
    # looks like after the exporter fix: nil, not a fabricated 0.
    cat = catalog([table("events", %{"reltuples" => nil, "n_live_tup" => nil})])
    assert Catalog.scale(cat, "events") == :unknown
  end

  test "CRDB-engine snapshot: nil/nil row is :unknown, never zero" do
    # Same shape as the exporter now produces for a CRDB table whose
    # `estimated_row_count` was a literal 0 (indistinguishable from "no
    # stats yet") — Cerbero.Snapshot.Exporter.crdb_row_counts/2 maps that
    # 0 to nil before it ever reaches the catalog, so this is what a fresh
    # CRDB table looks like at judgment time.
    crdb_engine = %{
      "engine" => %{"name" => "cockroachdb", "version" => "25.1", "version_num" => 25_100}
    }

    cat =
      catalog(
        [table("events", %{"reltuples" => nil, "n_live_tup" => nil})],
        crdb_engine
      )

    assert Catalog.scale(cat, "events") == :unknown
  end

  test "reltuples nil but n_live_tup known: falls back to n_live_tup, not :unknown" do
    cat = catalog([table("events", %{"reltuples" => nil, "n_live_tup" => 3_000})])
    assert {:rows, 3_000, _} = Catalog.scale(cat, "events")
  end

  test "a partition with both reltuples and n_live_tup nil poisons the parent's sum to :unknown" do
    cat =
      catalog([
        table("events", %{"partitioned" => true, "reltuples" => nil, "n_live_tup" => nil}),
        table("events_p0", %{
          "partition_of" => "public.events",
          "reltuples" => nil,
          "n_live_tup" => nil
        }),
        table("events_p1", %{
          "partition_of" => "public.events",
          "n_live_tup" => 250,
          "reltuples" => 250.0
        })
      ])

    assert Catalog.scale(cat, "events") == :unknown
  end

  test "dropping a partition removes it from the parent's sum" do
    cat =
      catalog([
        table("events", %{"partitioned" => true, "reltuples" => 0.0, "n_live_tup" => 0}),
        table("events_p0", %{
          "partition_of" => "public.events",
          "n_live_tup" => 100,
          "reltuples" => 100.0,
          "heap_bytes" => 10
        }),
        table("events_p1", %{
          "partition_of" => "public.events",
          "n_live_tup" => 250,
          "reltuples" => 250.0,
          "heap_bytes" => 20
        })
      ])

    dropped = Catalog.apply(cat, %Op.DropTable{table: "events_p0"})

    assert Catalog.scale(dropped, "events") == {:rows, 250, 20}
    refute Catalog.known?(dropped, "events_p0")
  end

  test "dropping every partition degrades the parent's sum to :unknown, not zero" do
    cat =
      catalog([
        table("events", %{"partitioned" => true, "reltuples" => 0.0, "n_live_tup" => 0}),
        table("events_p0", %{
          "partition_of" => "public.events",
          "n_live_tup" => 100,
          "reltuples" => 100.0
        })
      ])

    dropped = Catalog.apply(cat, %Op.DropTable{table: "events_p0"})

    assert Catalog.scale(dropped, "events") == :unknown
  end

  test "dropping the partitioned parent itself: scale is :unknown, table no longer known" do
    cat =
      catalog([
        table("events", %{"partitioned" => true, "reltuples" => 0.0, "n_live_tup" => 0}),
        table("events_p0", %{
          "partition_of" => "public.events",
          "n_live_tup" => 100,
          "reltuples" => 100.0
        })
      ])

    dropped = Catalog.apply(cat, %Op.DropTable{table: "events"})

    assert Catalog.scale(dropped, "events") == :unknown
    refute Catalog.known?(dropped, "events")
  end

  test "raw SQL DROP TABLE of a partition removes it from the parent's sum too" do
    cat =
      catalog([
        table("events", %{"partitioned" => true, "reltuples" => 0.0, "n_live_tup" => 0}),
        table("events_p0", %{
          "partition_of" => "public.events",
          "n_live_tup" => 100,
          "reltuples" => 100.0,
          "heap_bytes" => 10
        }),
        table("events_p1", %{
          "partition_of" => "public.events",
          "n_live_tup" => 250,
          "reltuples" => 250.0,
          "heap_bytes" => 20
        })
      ])

    op = %Op.RawSQL{
      classified: [%Classified{class: :drop_table, table: "events_p0"}]
    }

    dropped = Catalog.apply(cat, op)

    assert Catalog.scale(dropped, "events") == {:rows, 250, 20}
  end

  test "pending CreateTable over a partition's name: the reborn table leaves the parent's sum" do
    # born_table/3 gives overlay-born tables partition_of nil, so a
    # drop-then-recreate (or plain recreate) of a partition's name must not
    # keep contributing the old partition's rows to the parent.
    cat =
      catalog([
        table("events", %{"partitioned" => true, "reltuples" => 0.0, "n_live_tup" => 0}),
        table("events_p0", %{
          "partition_of" => "public.events",
          "n_live_tup" => 100,
          "reltuples" => 100.0,
          "heap_bytes" => 10
        }),
        table("events_p1", %{
          "partition_of" => "public.events",
          "n_live_tup" => 250,
          "reltuples" => 250.0,
          "heap_bytes" => 20
        })
      ])

    reborn = Catalog.apply(cat, %Op.CreateTable{table: "events_p0", columns: []})

    assert Catalog.scale(reborn, "events") == {:rows, 250, 20}
  end

  test "degraded staleness makes every scale unknown" do
    cat = catalog([table("events", %{"n_live_tup" => 5})], %{}, scale_mode: :unbounded)
    assert Catalog.scale(cat, "events") == :unknown
  end

  test "traffic: counters normalized by stats_reset age", %{config: config} do
    # collected_at 2026-07-01, stats_reset 2026-01-01: ~15.6M seconds.
    hot = catalog([table("flags", %{"idx_scan" => 40_000_000, "n_tup_upd" => 1_000_000})])
    cold = catalog([table("flags", %{"idx_scan" => 12, "n_tup_upd" => 3})])
    assert Catalog.traffic(hot, "flags", config) == :hot
    assert Catalog.traffic(cold, "flags", config) == :cold
  end

  test "standby snapshot yields unknown traffic and unknown-friendly stats", %{config: config} do
    cat = catalog([table("flags")], %{"standby" => true, "stats_provenance" => "standby"})
    assert Catalog.traffic(cat, "flags", config) == :unknown
  end

  test "lookup helpers", %{config: _} do
    t =
      table("events", %{
        "columns" => [column("org_id", %{"not_null" => false})],
        "indexes" => [index("events_org_id_index", ["org_id"])],
        "constraints" => [
          %{
            "columns" => [],
            "is_not_null_check_on" => "org_id",
            "name" => "org_id_nn",
            "on_delete" => nil,
            "on_update" => nil,
            "references" => nil,
            "type" => "check",
            "validated" => true
          }
        ]
      })

    cat = catalog([t])
    assert Catalog.has_index_leading_on?(cat, "events", "org_id")
    refute Catalog.has_index_leading_on?(cat, "events", "id")
    assert Catalog.validated_not_null_check?(cat, "events", "org_id")
    assert %{name: "org_id"} = Catalog.column(cat, "events", "org_id")
  end

  test "partitioned parent with no partition entries: unknown scale, not zero" do
    # Regression: empty partition list should return :unknown, not {:rows, 0, 0}
    cat =
      catalog([
        table("events", %{
          "partitioned" => true,
          "reltuples" => 0.0,
          "n_live_tup" => 0,
          "heap_bytes" => 0
        })
      ])

    assert Catalog.scale(cat, "events") == :unknown
  end

  test "empty catalog: replay source with unbounded scale" do
    cat = Catalog.empty()
    assert cat.source == :replay
    assert cat.scale_mode == :unbounded
    assert Catalog.scale(cat, "anything") == :unknown
    refute Catalog.known?(cat, "anything")
  end

  test "empty catalog with custom engine and version" do
    cat = Catalog.empty(:cockroachdb, 210_000)
    assert cat.engine == :cockroachdb
    assert cat.version_num == 210_000
    assert cat.source == :replay
    assert cat.scale_mode == :unbounded
  end
end
