defmodule Cerbero.Check.SnapshotHealth do
  @moduledoc """
  Rule 8: the snapshot's own health, surfaced as findings — never silent
  decay, never exit 2. Staleness degrades confidence; absence is never
  safety.
  """

  alias Cerbero.Catalog
  alias Cerbero.Check.Helpers
  alias Cerbero.Config
  alias Cerbero.DDL.Effects
  alias Cerbero.Finding
  alias Cerbero.Migration
  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Staleness

  @id :snapshot_health

  def id, do: @id

  # Not `@impl Cerbero.Check`: this module deliberately does not adopt the
  # behaviour (it runs outside the Runner fold), but it still describes
  # itself the same way regular checks do.
  def description, do: "The snapshot itself is degraded: stale, divergent, invalid indexes, or standby stats"

  @spec run_global(
          Snapshot.t(),
          Staleness.t(),
          [Migration.t()],
          [Migration.t()],
          Catalog.t(),
          Config.t()
        ) ::
          [Finding.t()]
  def run_global(snapshot, staleness, all_migrations, pending, catalog, config) do
    # One derive pass over the whole pending set, shared by
    # absent_table_findings and stats_age_findings (each used to derive it
    # independently). Effects.derive/3 depends only on the op and the
    # engine/version pair, and Catalog.apply/2 never changes engine or
    # version_num — so deriving against the base catalog here is identical
    # to deriving inside absent_table_findings' migration-local fold.
    derived =
      for m <- pending do
        {m, Enum.flat_map(m.operations, &Effects.derive(&1, catalog.engine, catalog.version_num))}
      end

    age_findings(staleness, config) ++
      invalid_index_findings(snapshot) ++
      divergence_findings(snapshot, all_migrations) ++
      aged_pending_findings(snapshot, pending, config) ++
      standby_findings(snapshot) ++
      absent_table_findings(derived, catalog) ++
      stats_age_findings(snapshot, derived, catalog, config)
  end

  defp age_findings(%Staleness{age_days: age}, %Config{} = c) do
    cond do
      age > c.stale_degrade_days ->
        [
          Helpers.finding(
            __MODULE__,
            :warning,
            "snapshot is #{age} days old (limit #{c.stale_degrade_days}): every row count is now " <>
              "treated as unknown -> unbounded; risky operations fire at warning or above. Re-export",
            nil,
            nil
          )
        ]

      age > c.stale_warn_days ->
        [
          Helpers.finding(
            __MODULE__,
            :warning,
            "snapshot is #{age} days old (warn threshold #{c.stale_warn_days}); re-export soon",
            nil,
            nil
          )
        ]

      true ->
        []
    end
  end

  defp invalid_index_findings(%Snapshot{tables: tables}) do
    for t <- tables, idx <- t.indexes, idx.valid == false do
      Helpers.finding(
        __MODULE__,
        :warning,
        "index #{t.schema}.#{t.name}.#{idx.name} is invalid in production — likely a failed " <>
          "CONCURRENTLY build: it costs writes and provides nothing; drop and rebuild it",
        nil,
        nil,
        relations: ["#{t.schema}.#{t.name}"]
      )
    end
  end

  defp divergence_findings(%Snapshot{applied_migrations: applied}, all_migrations) do
    case applied do
      [] ->
        []

      _ ->
        max_applied = Enum.max(applied)
        applied_set = MapSet.new(applied)

        for m <- all_migrations,
            m.version != nil,
            m.version <= max_applied,
            not MapSet.member?(applied_set, m.version) do
          Helpers.finding(
            __MODULE__,
            :warning,
            "migration #{m.version} exists in the repo with version <= max(applied) but is absent from " <>
              "the snapshot's applied list — snapshot and repo disagree about history",
            m,
            nil
          )
        end
    end
  end

  # Grace window: a migration authored within one deploy cycle of the
  # snapshot is normal PR churn (under nightly refresh, warning on every
  # predating migration flags most open PRs). Only past deploy_cadence days
  # does "still pending" become a stale-deploy signal worth surfacing.
  defp aged_pending_findings(%Snapshot{collected_at: collected_at}, pending, %Config{} = config) do
    grace_seconds = config.deploy_cadence * 86_400

    for m <- pending,
        m.version != nil,
        version_datetime = version_to_datetime(m.version),
        version_datetime != nil,
        DateTime.diff(collected_at, version_datetime, :second) > grace_seconds do
      Helpers.finding(
        __MODULE__,
        :warning,
        "pending migration #{m.version} predates the snapshot (#{DateTime.to_date(collected_at)}) " <>
          "by more than deploy_cadence (#{config.deploy_cadence}d) — it may already be applied " <>
          "(pending vs applied-after-snapshot is offline-indistinguishable); re-export",
        m,
        nil
      )
    end
  end

  defp version_to_datetime(<<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2>>) do
    case DateTime.from_iso8601("#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}Z") do
      {:ok, dt, 0} -> dt
      _ -> nil
    end
  end

  defp version_to_datetime(_), do: nil

  defp standby_findings(%Snapshot{standby: true}) do
    [
      Helpers.finding(
        __MODULE__,
        :warning,
        "snapshot was taken on a hot standby: pg_stat activity counters are instance-local " <>
          "(n_live_tup ~ 0, analyze timestamps NULL) — traffic judgments are degraded",
        nil,
        nil
      )
    ]
  end

  defp standby_findings(_), do: []

  # Per-table stats age (roadmap item 9): an error-tier table whose
  # statistics were already older than stale_warn_days when the snapshot
  # was exported (or never analyzed at all) gets an explicit
  # confidence-reduction warning, instead of only showing an old date
  # inside other rules' messages. Scoped to tables the pending set
  # actually targets — those are the judgments the stale stats degrade.
  # Standby snapshots are excluded: their timestamps are NULL by
  # mechanism and standby_findings/1 already covers that.
  defp stats_age_findings(%Snapshot{standby: true}, _derived, _catalog, _config), do: []

  defp stats_age_findings(%Snapshot{} = snapshot, derived, catalog, config) do
    targeted = targeted_tables(derived)

    for t <- snapshot.tables,
        qualified = "#{t.schema}.#{t.name}",
        MapSet.member?(targeted, qualified),
        error_tier?(catalog, qualified, config),
        age = stats_age_days(t, snapshot.collected_at),
        age == :never or age > config.stale_warn_days do
      message =
        case age do
          :never ->
            "#{qualified} is at error-tier scale but the snapshot has no analyze timestamp " <>
              "for it (never analyzed, or stats reset) — its row estimates are low-confidence; " <>
              "ANALYZE and re-export"

          days ->
            "#{qualified} is at error-tier scale but its statistics were already #{days} days " <>
              "old at export (threshold #{config.stale_warn_days}d) — its row estimates are " <>
              "low-confidence; ANALYZE and re-export"
        end

      Helpers.finding(__MODULE__, :warning, message, nil, nil, relations: [qualified])
    end
  end

  defp targeted_tables(derived) do
    for {_m, effects} <- derived,
        effect <- effects,
        {_role, table} <- effect.relations,
        is_binary(table),
        into: MapSet.new() do
      Catalog.qualify(table)
    end
  end

  defp error_tier?(catalog, qualified, %Config{} = c) do
    case Catalog.scale(catalog, qualified) do
      {:rows, rows, bytes} ->
        rows >= c.rows_error * catalog.multiplier or bytes >= c.bytes_error * catalog.multiplier

      _ ->
        false
    end
  end

  defp stats_age_days(t, collected_at) do
    case Enum.reject([t.last_analyze, t.last_autoanalyze], &is_nil/1) do
      [] ->
        :never

      stamps ->
        newest = Enum.max(stamps, DateTime)
        div(DateTime.diff(collected_at, newest, :second), 86_400)
    end
  end

  # Absent-and-not-created-by-pending => unknown scale + a demand for re-export.
  # The catalog fold is still per-migration (migration N must see tables
  # created by 1..N-1); only the effects are pre-derived, see run_global/6.
  defp absent_table_findings(derived, catalog) do
    {findings, _cat} =
      Enum.flat_map_reduce(derived, catalog, fn {m, effects}, cat ->
        findings =
          effects
          |> Enum.reject(&(&1.class == :create_table))
          |> Enum.flat_map(fn effect ->
            for {_role, table} <- effect.relations,
                is_binary(table),
                not Catalog.known?(cat, table) do
              Helpers.finding(
                __MODULE__,
                :error,
                "pending migration targets #{Catalog.qualify(table)}, which is absent from the snapshot " <>
                  "and not created by the pending set — absence is never safety; re-export the snapshot",
                m,
                effect.line,
                relations: [Catalog.qualify(table)]
              )
            end
          end)

        {findings, Catalog.apply_migration(cat, m)}
      end)

    Enum.uniq_by(findings, &{&1.file, &1.line, &1.message})
  end
end
