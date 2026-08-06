defmodule Cerbero.Check.RunnerTest do
  use ExUnit.Case, async: true

  alias Cerbero.{Catalog, Config, Finding, Migration}
  alias Cerbero.Check.Runner
  alias Cerbero.Migration.Parser
  import Cerbero.Test.SnapshotBuilder

  defp parse!(version, body) do
    {:ok, m} =
      Parser.parse_string(
        "defmodule M#{version} do\n use Ecto.Migration\n def change do\n #{body}\n end\nend",
        "#{version}_m.exs"
      )

    m
  end

  defp catalog(tables \\ []) do
    Catalog.from_snapshot(
      build_snapshot(%{"tables" => tables}),
      %Cerbero.Snapshot.Staleness{age_days: 1, scale_mode: :exact, threshold_multiplier: 1.0}
    )
  end

  setup do
    {:ok, config} = Config.load("nonexistent")
    %{config: config}
  end

  test "select_pending: applied and pre-cutoff migrations are excluded" do
    migrations = [
      %Migration{version: "20250101000000"},
      %Migration{version: "20260801000000"},
      %Migration{version: "20260801000001"}
    ]

    assert [%{version: "20260801000000"}, %{version: "20260801000001"}] =
             Runner.select_pending(migrations, ["20250101000000"], nil)

    assert [%{version: "20260801000001"}] =
             Runner.select_pending(migrations, [], "20260801000000")
  end

  test "overlay threads between migrations: migration 2 sees migration 1's table", %{
    config: config
  } do
    m1 = parse!("20260801000000", "create table(:events_v2) do\n add :org_id, :bigint\n end")
    m2 = parse!("20260801000001", "create index(:events_v2, [:org_id])")

    {_findings, final} = Runner.run([m1, m2], catalog(), config)
    assert Catalog.has_index_leading_on?(final, "events_v2", "org_id")
  end

  test "meta-findings: unclassified SQL and unknown operations warn", %{config: config} do
    m =
      parse!("20260801000000", """
      execute "CLUSTER events USING idx"
      for t <- [:a], do: create(index(t, [:x]))
      """)

    {findings, _} = Runner.run([m], catalog([table("events")]), config)
    assert Enum.any?(findings, &(&1.check == :unclassified_sql and &1.severity == :warning))
    assert Enum.any?(findings, &(&1.check == :unknown_operation and &1.severity == :warning))
  end

  test "@cerbero_skip demotes to info with reason visible", %{config: config} do
    {:ok, m} =
      Parser.parse_string("""
      defmodule M do
        use Ecto.Migration
        @cerbero_skip [{:unclassified_sql, "reviewed by DBA 2026-08-01"}]
        def change do
          execute "CLUSTER events USING idx"
        end
      end
      """)

    {findings, _} = Runner.run([m], catalog([table("events")]), config)

    assert [%Finding{check: :unclassified_sql, severity: :info, message: msg}] =
             Enum.filter(findings, &(&1.check == :unclassified_sql))

    assert msg =~ "reviewed by DBA 2026-08-01"
  end

  test "severity_overrides floor from config", %{config: config} do
    config = %{config | severity_overrides: %{unclassified_sql: :error}}
    m = parse!("20260801000000", ~s|execute "CLUSTER events USING idx"|)
    {findings, _} = Runner.run([m], catalog(), config)
    assert [%Finding{severity: :error}] = Enum.filter(findings, &(&1.check == :unclassified_sql))
  end

  test "lock_timeout_attested annotates AEL/lock_timeout findings without changing severity or silencing",
       %{config: config} do
    m =
      parse!(
        "20260801000000",
        "alter table(:events) do\n modify :org_id, :bigint, null: false\n end"
      )

    events =
      table("events", %{
        "n_live_tup" => 5_000_000,
        "reltuples" => 5_000_000.0,
        "columns" => [column("org_id")]
      })

    {findings_off, _} =
      Runner.run([m], catalog([events]), config, [Cerbero.Check.NotNullOnPopulatedTable])

    assert [%Finding{severity: :error, message: msg_off}] = findings_off
    refute msg_off =~ "lock_timeout attested"

    config_on = %{config | lock_timeout_attested: true}

    {findings_on, _} =
      Runner.run([m], catalog([events]), config_on, [Cerbero.Check.NotNullOnPopulatedTable])

    assert [%Finding{severity: :error, message: msg_on}] = findings_on
    assert msg_on == msg_off <> " (lock_timeout attested in .cerbero.exs)"
  end

  test "lock_timeout_attested leaves findings that don't mention a lock untouched", %{
    config: config
  } do
    config_on = %{config | lock_timeout_attested: true}
    m = parse!("20260801000000", ~s|execute "CLUSTER events USING idx"|)
    {findings, _} = Runner.run([m], catalog(), config_on)

    assert [%Finding{message: msg}] = Enum.filter(findings, &(&1.check == :unclassified_sql))
    refute msg =~ "lock_timeout attested"
  end

  test "helpers: human_rows" do
    assert Cerbero.Check.Helpers.human_rows(412_000_000) == "412M"
    assert Cerbero.Check.Helpers.human_rows(41_000_000) == "41M"
    assert Cerbero.Check.Helpers.human_rows(600_000) == "600k"
    assert Cerbero.Check.Helpers.human_rows(97) == "97"
  end

  test "config.skip_checks demotes findings to info without silencing them", %{config: config} do
    config = %{config | skip_checks: [:meta_findings]}
    m = parse!("20260801000000", ~s|execute "CLUSTER events USING idx"|)
    {findings, _} = Runner.run([m], catalog(), config)

    assert [%Finding{check: :unclassified_sql, severity: :info, message: msg}] =
             Enum.filter(findings, &(&1.check == :unclassified_sql))

    assert msg =~ "(skipped via config)"
  end

  test "@cerbero_skip wins over severity_overrides, but overrides apply to other migrations",
       %{config: config} do
    config = %{config | severity_overrides: %{unclassified_sql: :error}}

    {:ok, m_skipped} =
      Parser.parse_string("""
      defmodule M do
        use Ecto.Migration
        @cerbero_skip [{:unclassified_sql, "reviewed"}]
        def change do
          execute "CLUSTER events USING idx"
        end
      end
      """)

    m_not_skipped = parse!("20260801000001", ~s|execute "CLUSTER events USING idx"|)

    {findings, _} = Runner.run([m_skipped, m_not_skipped], catalog(), config)

    skipped_findings =
      Enum.filter(findings, &(&1.check == :unclassified_sql and &1.file == "inline.exs"))

    not_skipped_findings =
      Enum.filter(
        findings,
        &(&1.check == :unclassified_sql and &1.file == "20260801000001_m.exs")
      )

    assert [%Finding{severity: :info, message: msg}] = skipped_findings
    assert msg =~ "reviewed"
    assert [%Finding{severity: :error}] = not_skipped_findings
  end
end
