defmodule Cerbero.Snapshot.BucketingTest do
  use ExUnit.Case, async: true

  import Cerbero.Test.SnapshotBuilder

  alias Cerbero.Snapshot.Bucketing

  describe "bucket/1" do
    test "buckets positive numbers to the power-of-ten floor" do
      assert Bucketing.bucket(1) == 1
      assert Bucketing.bucket(9) == 1
      assert Bucketing.bucket(10) == 10
      assert Bucketing.bucket(5_000) == 1_000
      assert Bucketing.bucket(99_999) == 10_000
      assert Bucketing.bucket(100_000) == 100_000
      assert Bucketing.bucket(412_000_000) == 100_000_000
    end

    test "floats bucket to float powers of ten" do
      assert Bucketing.bucket(412_000_000.0) == 100_000_000.0
      assert Bucketing.bucket(41.0) == 10.0
    end

    test "zero, negatives, and nil pass through untouched" do
      assert Bucketing.bucket(0) == 0
      assert Bucketing.bucket(nil) == nil
      # PG >= 14 never-analyzed sentinel must survive as-is
      assert Bucketing.bucket(-1.0) == -1.0
    end
  end

  describe "apply/1 on a raw snapshot map" do
    test "buckets counts and bytes on tables and indexes, leaves identity fields alone" do
      raw =
        build(%{
          "tables" => [
            table("subscriptions", %{
              "reltuples" => 4_120_000.0,
              "n_live_tup" => 4_123_456,
              "relpages" => 52_345,
              "heap_bytes" => 2_147_483_648,
              "total_bytes" => 3_221_225_472,
              "seq_scan" => 12,
              "idx_scan" => 987_654,
              "n_tup_ins" => 45_000,
              "n_tup_upd" => 7,
              "n_tup_del" => 0,
              "indexes" => [index("subscriptions_pkey", ["id"], %{"bytes" => 123_456_789})]
            })
          ]
        })

      bucketed = Bucketing.apply(raw)
      [t] = bucketed["tables"]

      assert t["reltuples"] == 1_000_000.0
      assert t["n_live_tup"] == 1_000_000
      assert t["relpages"] == 10_000
      assert t["heap_bytes"] == 1_000_000_000
      assert t["total_bytes"] == 1_000_000_000
      assert t["seq_scan"] == 10
      assert t["idx_scan"] == 100_000
      assert t["n_tup_ins"] == 10_000
      assert t["n_tup_upd"] == 1
      assert t["n_tup_del"] == 0
      assert [%{"bytes" => 100_000_000}] = t["indexes"]

      # identity/shape fields untouched
      assert t["name"] == "subscriptions"
      assert t["schema"] == "public"
      assert length(t["columns"]) == 1
    end

    test "bucketed output still passes strict decode after stamping" do
      raw = build(%{"tables" => [table("events", %{"n_live_tup" => 412_000_000})]})
      bucketed = raw |> Bucketing.apply() |> Cerbero.Snapshot.stamp()
      assert {:ok, snapshot} = Cerbero.Snapshot.decode(bucketed)
      assert [%{n_live_tup: 100_000_000}] = snapshot.tables
    end

    test "verdicts survive: default row tiers are powers of ten, so bucket floors preserve them" do
      # 600k exact -> warning tier (>= 100k); bucket floor 100k -> still >= 100k
      # 2M exact -> error tier (>= 1M); bucket floor 1M -> still >= 1M
      {:ok, config} = Cerbero.Config.load("nonexistent")
      assert Bucketing.bucket(600_000) >= config.rows_warning
      assert Bucketing.bucket(2_000_000) >= config.rows_error
    end
  end

  describe "finalize/2 (the exporter's entry point)" do
    test ":exact stamps the precision field and buckets nothing" do
      raw = build(%{"tables" => [table("events", %{"n_live_tup" => 412_345})]})
      finalized = Bucketing.finalize(raw, :exact)
      assert finalized["precision"] == "exact"
      assert [%{"n_live_tup" => 412_345}] = finalized["tables"]
    end

    test ":order_of_magnitude stamps the field and buckets" do
      raw = build(%{"tables" => [table("events", %{"n_live_tup" => 412_345})]})
      finalized = Bucketing.finalize(raw, :order_of_magnitude)
      assert finalized["precision"] == "order_of_magnitude"
      assert [%{"n_live_tup" => 100_000}] = finalized["tables"]

      assert {:ok, %Cerbero.Snapshot{precision: :order_of_magnitude}} =
               finalized |> Cerbero.Snapshot.stamp() |> Cerbero.Snapshot.decode()
    end
  end
end
