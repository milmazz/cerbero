defmodule Cerbero.Check.RunnerTest.EchoCheck do
  @moduledoc false
  @behaviour Cerbero.Check

  @impl true
  def id, do: :echo_check

  @impl true
  def run(migration, _catalog, _config) do
    [
      %Cerbero.Finding{
        check: :echo_check,
        severity: :warning,
        message: "echo finding",
        file: migration.file
      }
    ]
  end
end

defmodule Cerbero.Check.RunnerTest do
  use ExUnit.Case, async: true

  import Cerbero.Test.SnapshotBuilder

  alias Cerbero.Catalog
  alias Cerbero.Check.FKValidationScan
  alias Cerbero.Check.Helpers
  alias Cerbero.Check.NotNullOnPopulatedTable
  alias Cerbero.Check.Runner
  alias Cerbero.Check.RunnerTest.EchoCheck
  alias Cerbero.Config
  alias Cerbero.Finding
  alias Cerbero.Migration
  alias Cerbero.Migration.Parser

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

  test "select_pending: a nil-version migration survives a start_after cutoff" do
    migrations = [%Migration{version: nil, file: "unversioned.exs"}]

    assert [%{version: nil}] = Runner.select_pending(migrations, [], "20260801000000")
  end

  test "split_pending: nil-version migrations are always pending, even with start_after set" do
    migrations = [
      %Migration{version: "20250101000000"},
      %Migration{version: nil, file: "unversioned.exs"},
      %Migration{version: "20260801000001"}
    ]

    {history, pending} = Runner.split_pending(migrations, [], "20260801000000")

    assert [%{version: "20250101000000"}] = history
    assert [%{version: nil}, %{version: "20260801000001"}] = pending
  end

  test "split_pending: applied versions land in history; pending is sorted by version" do
    migrations = [
      %Migration{version: "20260801000001"},
      %Migration{version: "20250101000000"},
      %Migration{version: "20260801000000"}
    ]

    {history, pending} = Runner.split_pending(migrations, ["20250101000000"], nil)

    assert [%{version: "20250101000000"}] = history
    assert [%{version: "20260801000000"}, %{version: "20260801000001"}] = pending
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

    assert [%Finding{check: :unclassified_sql, severity: :info, message: msg, metadata: metadata}] =
             Enum.filter(findings, &(&1.check == :unclassified_sql))

    assert msg =~ "reviewed by DBA 2026-08-01"

    assert metadata.skipped == %{
             via: :migration_attribute,
             reason: "reviewed by DBA 2026-08-01"
           }
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
      Runner.run([m], catalog([events]), config, [NotNullOnPopulatedTable])

    assert [%Finding{severity: :error, message: msg_off}] = findings_off
    refute msg_off =~ "lock_timeout attested"

    config_on = %{config | lock_timeout_attested: true}

    {findings_on, _} =
      Runner.run([m], catalog([events]), config_on, [NotNullOnPopulatedTable])

    assert [%Finding{severity: :error, message: msg_on}] = findings_on
    assert msg_on == msg_off <> " (lock_timeout attested in .cerbero.exs)"
  end

  test "lock_timeout_attested annotates SHARE ROW EXCLUSIVE findings (fk_validation_scan) via lock metadata",
       %{config: config} do
    m =
      parse!(
        "20260801000000",
        "alter table(:events) do\n add :owner_org_id, references(:orgs)\n end"
      )

    tables = [
      table("events", %{"n_live_tup" => 412_000_000, "reltuples" => 412_000_000.0}),
      table("orgs", %{"n_live_tup" => 41_000_000, "reltuples" => 41_000_000.0})
    ]

    config_on = %{config | lock_timeout_attested: true}

    {findings, _} = Runner.run([m], catalog(tables), config_on, [FKValidationScan])

    assert [%Finding{check: :fk_validation_scan, severity: :error, message: msg}] = findings
    assert msg =~ "SHARE ROW EXCLUSIVE"
    assert String.ends_with?(msg, " (lock_timeout attested in .cerbero.exs)")
  end

  test "lock_timeout_attested leaves findings without lock metadata untouched", %{
    config: config
  } do
    config_on = %{config | lock_timeout_attested: true}
    m = parse!("20260801000000", ~s|execute "CLUSTER events USING idx"|)
    {findings, _} = Runner.run([m], catalog(), config_on)

    assert [%Finding{message: msg}] = Enum.filter(findings, &(&1.check == :unclassified_sql))
    refute msg =~ "lock_timeout attested"
  end

  test "extra_checks from config run alongside the default checks", %{config: config} do
    config = %{config | extra_checks: [EchoCheck]}
    m = parse!("20260801000000", "create table(:events_v2) do\n add :x, :bigint\n end")

    {findings, _} = Runner.run([m], catalog(), config)

    assert Enum.any?(findings, &(&1.check == :echo_check and &1.severity == :warning))
  end

  test "runner machinery (skip_checks demotion) applies to registered third-party checks", %{
    config: config
  } do
    config = %{
      config
      | extra_checks: [EchoCheck],
        skip_checks: [:echo_check]
    }

    m = parse!("20260801000000", "create table(:events_v2) do\n add :x, :bigint\n end")
    {findings, _} = Runner.run([m], catalog(), config)

    assert [%Finding{check: :echo_check, severity: :info, message: msg}] =
             Enum.filter(findings, &(&1.check == :echo_check))

    assert msg =~ "(skipped via config)"
  end

  test "a builtin listed in extra_checks does not run twice", %{config: config} do
    config = %{config | extra_checks: [Cerbero.Check.MetaFindings]}
    m = parse!("20260801000000", ~s|execute "CLUSTER events USING idx"|)

    {findings, _} = Runner.run([m], catalog(), config)

    assert [_] = Enum.filter(findings, &(&1.check == :unclassified_sql))
  end

  test "helpers: human_rows" do
    assert Helpers.human_rows(412_000_000) == "412M"
    assert Helpers.human_rows(41_000_000) == "41M"
    assert Helpers.human_rows(600_000) == "600k"
    assert Helpers.human_rows(97) == "97"
  end

  test "config.skip_checks demotes findings to info without silencing them", %{config: config} do
    config = %{config | skip_checks: [:meta_findings]}
    m = parse!("20260801000000", ~s|execute "CLUSTER events USING idx"|)
    {findings, _} = Runner.run([m], catalog(), config)

    assert [%Finding{check: :unclassified_sql, severity: :info, message: msg, metadata: metadata}] =
             Enum.filter(findings, &(&1.check == :unclassified_sql))

    assert msg =~ "(skipped via config)"
    assert metadata.skipped == %{via: :config}
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
