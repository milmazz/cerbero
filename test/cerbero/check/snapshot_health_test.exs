defmodule Cerbero.Check.SnapshotHealthTest do
  use ExUnit.Case, async: true

  alias Cerbero.{Catalog, Config, Migration}
  alias Cerbero.Check.SnapshotHealth
  alias Cerbero.Migration.Parser
  alias Cerbero.Snapshot.Staleness
  import Cerbero.Test.SnapshotBuilder

  defp run_health(opts) do
    snapshot = build_snapshot(Keyword.get(opts, :snapshot, %{}))
    age = Keyword.get(opts, :age_days, 1)
    {:ok, config} = Config.load("nonexistent")

    staleness = %Staleness{
      age_days: age,
      scale_mode: if(age > config.stale_degrade_days, do: :unbounded, else: :exact),
      threshold_multiplier: if(age > config.headroom_days, do: 0.5, else: 1.0)
    }

    catalog = Catalog.from_snapshot(snapshot, staleness)

    SnapshotHealth.run_global(
      snapshot,
      staleness,
      Keyword.get(opts, :all, []),
      Keyword.get(opts, :pending, []),
      catalog,
      config
    )
  end

  defp pending!(version, body) do
    {:ok, m} =
      Parser.parse_string(
        "defmodule P#{version} do\n use Ecto.Migration\n def change do\n #{body}\n end\nend",
        "#{version}_p.exs"
      )

    m
  end

  test "age past 30 days warns; fresh does not" do
    assert [] = run_health(age_days: 3)

    assert Enum.any?(
             run_health(age_days: 45),
             &(&1.severity == :warning and &1.message =~ "45 days old")
           )
  end

  test "age past 90 days states that scale is degraded to unbounded" do
    assert Enum.any?(run_health(age_days: 120), &(&1.message =~ "unbounded"))
  end

  test "invalid index in prod: a failed CONCURRENTLY build costing writes, providing nothing" do
    t =
      table("events", %{"indexes" => [index("events_bad_idx", ["org_id"], %{"valid" => false})]})

    findings = run_health(snapshot: %{"tables" => [t]})
    assert Enum.any?(findings, &(&1.message =~ "events_bad_idx" and &1.message =~ "invalid"))
  end

  test "history divergence: repo migration with version <= max(applied) but absent from applied" do
    findings =
      run_health(
        snapshot: %{"applied_migrations" => ["20250101000000", "20250301000000"]},
        all: [%Migration{version: "20250201000000", file: "x.exs"}]
      )

    assert Enum.any?(findings, &(&1.message =~ "20250201000000" and &1.severity == :warning))
  end

  test "aged-pending heuristic: pending migration older than the snapshot has likely been deployed" do
    findings = run_health(pending: [pending!("20250101000000", "create index(:x, [:y])")])
    assert Enum.any?(findings, &(&1.message =~ "already be applied"))
  end

  test "standby snapshot: degraded stats warning" do
    findings = run_health(snapshot: %{"standby" => true, "stats_provenance" => "standby"})
    assert Enum.any?(findings, &(&1.message =~ "standby"))
  end

  test "absent table targeted by pending DDL and not created by the pending set: error demanding re-export" do
    findings = run_health(pending: [pending!("20260901000000", "create index(:ghost, [:x])")])

    assert Enum.any?(
             findings,
             &(&1.severity == :error and &1.message =~ "ghost" and &1.message =~ "re-export")
           )
  end

  test "a table created by the pending set is NOT an absent-table error" do
    findings =
      run_health(
        pending: [
          pending!("20260901000000", "create table(:events_v2) do\n add :x, :bigint\n end"),
          pending!("20260901000001", "create index(:events_v2, [:x])")
        ]
      )

    refute Enum.any?(findings, &(&1.message =~ "events_v2"))
  end
end
