defmodule Cerbero.Test.RuleCase do
  @moduledoc "Shared scaffolding for rule tests: parse inline source, judge against a built snapshot."

  alias Cerbero.Test.SnapshotBuilder

  defmacro __using__(_) do
    quote do
      use ExUnit.Case, async: true
      import Cerbero.Test.SnapshotBuilder
      import Cerbero.Test.RuleCase
      alias Cerbero.{Catalog, Config, Finding}
    end
  end

  alias Cerbero.{Catalog, Config}
  alias Cerbero.Check.Runner
  alias Cerbero.Migration.Parser
  alias Cerbero.Snapshot.Staleness

  def judge(checks, tables, body, opts \\ []) do
    snapshot_overrides = Keyword.get(opts, :snapshot, %{})
    config_overrides = Keyword.get(opts, :config, [])
    attrs = Keyword.get(opts, :attrs, "")

    {:ok, migration} =
      Parser.parse_string(
        "defmodule M do\n use Ecto.Migration\n#{attrs}\n def change do\n #{body}\n end\nend",
        "20260801000000_m.exs"
      )

    snapshot =
      SnapshotBuilder.build_snapshot(Map.merge(%{"tables" => tables}, snapshot_overrides))

    staleness = %Staleness{age_days: 1, scale_mode: :exact, threshold_multiplier: 1.0}
    catalog = Catalog.from_snapshot(snapshot, staleness)
    {:ok, config} = Config.load("nonexistent")
    config = struct!(config, config_overrides)

    {findings, _catalog} = Runner.run([migration], catalog, config, checks)
    findings
  end

  def big_events_table do
    SnapshotBuilder.table("events", %{
      "n_live_tup" => 412_000_000,
      "reltuples" => 412_000_000.0,
      "heap_bytes" => 219_902_325_555,
      "total_bytes" => 253_403_070_464,
      "last_autoanalyze" => "2026-07-01T00:00:00Z",
      "columns" => [
        SnapshotBuilder.column("id", %{"not_null" => true}),
        SnapshotBuilder.column("org_id")
      ]
    })
  end
end
