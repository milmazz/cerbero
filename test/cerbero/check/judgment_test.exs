defmodule Cerbero.Check.JudgmentTest.FakeCheck do
  @moduledoc false
  @behaviour Cerbero.Check

  @impl true
  def id, do: :fake_check

  @impl true
  def run(_migration, _catalog, _config), do: []
end

defmodule Cerbero.Check.JudgmentTest do
  use ExUnit.Case, async: true

  import Cerbero.Test.SnapshotBuilder

  alias Cerbero.Catalog
  alias Cerbero.Check.Judgment
  alias Cerbero.Check.JudgmentTest.FakeCheck
  alias Cerbero.Config
  alias Cerbero.Finding
  alias Cerbero.Migration
  alias Cerbero.Snapshot.Staleness

  defp catalog(tables) do
    Catalog.from_snapshot(
      build_snapshot(%{"tables" => tables}),
      %Staleness{age_days: 1, scale_mode: :exact, threshold_multiplier: 1.0}
    )
  end

  defp big_events, do: table("events", %{"n_live_tup" => 412_000_000, "reltuples" => 412_000_000.0})
  defp small_orgs, do: table("orgs", %{"n_live_tup" => 40, "reltuples" => 40.0})

  @migration %Migration{file: "20260801000000_x.exs", version: "20260801000000"}
  @config struct!(Config, [])

  defp judge(params, cat, opts) do
    Judgment.judge(FakeCheck, params, @migration, cat, @config, opts)
  end

  test "nil table is silent (the caller could not name a target)" do
    assert [] =
             judge(
               %{table: nil, lock: :access_exclusive, cost: :rewrite, line: 3},
               catalog([big_events()]),
               message: fn -> "boom" end
             )
  end

  test "born-empty tables are silenced by the spine, not by each rule" do
    cat = Catalog.apply_migration(catalog([]), %Migration{operations: []})
    cat = Catalog.apply(cat, %Cerbero.Operation.CreateTable{table: "fresh", line: 1})

    assert [] =
             judge(
               %{table: "fresh", lock: :access_exclusive, cost: :rewrite, line: 3},
               cat,
               message: fn -> "boom" end
             )
  end

  test "assembles the finding: severity from Severity.assess, judged lock in metadata, default relations" do
    assert [%Finding{} = f] =
             judge(
               %{table: "events", lock: :access_exclusive, cost: :rewrite, line: 7},
               catalog([big_events()]),
               message: fn -> "rewrites everything" end
             )

    assert f.check == :fake_check
    assert f.severity == :error
    assert f.message == "rewrites everything"
    assert f.file == "20260801000000_x.exs"
    assert f.line == 7
    assert f.relations == ["public.events"]
    assert f.metadata == %{lock: :access_exclusive}
    assert f.engine == nil
  end

  test ":none is suppressed by default (small cold table, metadata-only)" do
    assert [] =
             judge(
               %{table: "orgs", lock: :share_update_exclusive, cost: :metadata_only, line: 1},
               catalog([small_orgs()]),
               message: fn -> "never built" end
             )
  end

  test "a severity override can floor the verdict regardless of scale (TRUNCATE-style)" do
    assert [%Finding{severity: :error}] =
             judge(
               %{table: "orgs", lock: :access_exclusive, cost: :metadata_only, line: 1},
               catalog([small_orgs()]),
               message: fn -> "destructive" end,
               severity: fn _ -> :error end
             )
  end

  test "also_assess: the most severe verdict across all named tables wins (FK-style)" do
    cat = catalog([small_orgs(), big_events()])

    # target alone would be quiet; the also-assessed big table escalates.
    assert [%Finding{severity: :error}] =
             judge(
               %{table: "orgs", lock: :share_row_exclusive, cost: :full_scan, line: 2},
               cat,
               message: fn -> "scans both" end,
               also_assess: ["events"],
               relations: ["public.orgs", "public.events"]
             )
  end

  test "nil entries in also_assess are ignored (unknown referenced table)" do
    assert [%Finding{relations: ["public.events"]}] =
             judge(
               %{table: "events", lock: :share_row_exclusive, cost: :full_scan, line: 2},
               catalog([big_events()]),
               message: fn -> "scans one" end,
               also_assess: [nil]
             )
  end
end
