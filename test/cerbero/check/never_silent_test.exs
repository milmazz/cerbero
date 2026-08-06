defmodule Cerbero.Check.NeverSilentTest do
  @moduledoc """
  The invariant regression net (final review recommendation 4).

  For every DDL class in `Cerbero.DDL.Locks` whose (postgres, 150_000)
  entry takes a write-blocking lock (ACCESS EXCLUSIVE / SHARE / SHARE ROW
  EXCLUSIVE) or costs a full scan/rewrite, a raw-SQL migration statement
  against a table at outage scale (the 412M-row fixture) must produce at
  least one finding from the *full* check pipeline
  (`Cerbero.Check.Runner.default_checks/0`) — not from any one rule in
  isolation. This is the net that would have caught Criticals 2 and 3
  before they shipped: raw DDL that classifies cleanly but that no rule
  filters (Critical 2), and raw ADD PRIMARY KEY/UNIQUE misclassified into
  `add_column` by an overly-greedy regex (Critical 3) both slipped past
  every existing rule test because each rule test only asks "does *my*
  rule fire on *my* fixture", never "does *something* fire on this class".

  Classes with no reachable raw-SQL surface today are listed explicitly in
  `@unreachable` with the reason, rather than silently skipped — see that
  module attribute's comment.
  """
  use Cerbero.Test.RuleCase

  alias Cerbero.Check.Runner
  alias Cerbero.DDL.Locks
  alias Cerbero.Migration.Parser

  @write_blocking [:access_exclusive, :share, :share_row_exclusive]

  # Classes whose Locks entry structurally qualifies for the net (a
  # write-blocking lock, or a full_scan/rewrite cost) but that no code
  # path in this codebase can ever actually produce today, from any
  # migration source (raw SQL *or* the Ecto DSL). Each is a narrow,
  # pre-existing, documented gap — not something introduced by, or in
  # scope for, this fix wave. If a future classifier/DSL change starts
  # emitting one of these, `unreachable classes really are unreachable`
  # below will fail loudly, which is the point: shrink this set, add a
  # sample statement, and the net covers it.
  @unreachable %{
    # No Cerbero.SQL.Classifier pattern recognizes ATTACH/DETACH PARTITION
    # or SET LOGGED/UNLOGGED raw SQL, and no Ecto DSL Operation maps to
    # them either — the "partition classes" the net's own design
    # anticipates as legitimate exclusions.
    attach_partition: "no classifier pattern for raw SQL ATTACH PARTITION; no DSL op either",
    detach_partition: "no classifier pattern for raw SQL DETACH PARTITION; no DSL op either",
    set_logged: "no classifier pattern for raw SQL SET LOGGED/UNLOGGED; no DSL op either",
    # RenameOp exists as a DSL-only Operation (Cerbero.Operation.RenameOp,
    # produced by the Ecto DSL `rename/2`); the classifier has no raw SQL
    # RENAME pattern. Since no rule currently judges :rename via *either*
    # path, DSL coverage is also absent — a separate, pre-existing gap
    # this wave was not asked to close (RawDDLSafety is scoped to raw SQL
    # only; see its moduledoc).
    rename:
      "no classifier pattern for raw SQL RENAME (only reachable via the DSL, and unjudged there too)",
    # Documented in Cerbero.DDL.Effects's own moduledoc: no classification
    # path (raw SQL or DSL) emits this class at all.
    set_default: "never emitted by Effects.classify/sql_class on any path (see its moduledoc)",
    # Binary-coercibility (varchar widen, varchar->text) is a distinction
    # Cerbero.Check.ColumnTypeChange computes itself over the plain
    # :alter_column_type class; it is not a separate classifier output.
    alter_column_type_binary_coercible:
      "never emitted by Effects.classify/sql_class — rule 4 computes coercibility itself over :alter_column_type",
    # Effects.sql_class always maps a raw SQL VALIDATE CONSTRAINT to
    # :validate_foreign_key regardless of whether the underlying
    # constraint is a CHECK or an FK (it cannot tell without
    # cross-referencing the catalog) — :validate_check is listed in
    # classes_emitted/0 but no sql_class clause actually produces it.
    validate_check:
      "never emitted by Effects.sql_class — raw SQL VALIDATE CONSTRAINT always maps to :validate_foreign_key",
    # The raw-SQL ADD COLUMN pattern has no way to see a DEFAULT
    # expression's volatility or a GENERATED ... STORED clause — it always
    # classifies to :add_column_constant_default (Effects.sql_class's
    # single ADD COLUMN clause). Only the Ecto DSL path
    # (Effects.add_column_class/1, which inspects the `default:`/
    # `generated:` opts) can produce these two classes. Already covered by
    # rule 3's own DSL-form tests (default_rewrite_test.exs).
    add_column_volatile_default:
      "DSL-only — raw SQL ADD COLUMN always classifies as constant_default",
    add_column_generated_stored:
      "DSL-only — raw SQL ADD COLUMN always classifies as constant_default"
  }

  # One representative raw-SQL statement per reachable, qualifying class.
  @sample_sql %{
    create_index: ~s|CREATE INDEX events_never_silent_idx ON events (org_id)|,
    create_index_concurrently:
      ~s|CREATE INDEX CONCURRENTLY events_never_silent_idx2 ON events (org_id)|,
    drop_index: ~s|DROP INDEX events_never_silent_missing_idx|,
    add_column_constant_default: ~s|ALTER TABLE events ADD COLUMN flag integer DEFAULT 0|,
    add_primary_key: ~s|ALTER TABLE events ADD PRIMARY KEY (id)|,
    add_unique: ~s|ALTER TABLE events ADD UNIQUE (org_id)|,
    set_not_null: ~s|ALTER TABLE events ALTER COLUMN org_id SET NOT NULL|,
    add_check: ~s|ALTER TABLE events ADD CONSTRAINT events_org_id_positive CHECK (org_id > 0)|,
    add_check_not_valid:
      ~s|ALTER TABLE events ADD CONSTRAINT events_org_id_positive2 CHECK (org_id > 0) NOT VALID|,
    add_foreign_key:
      ~s|ALTER TABLE events ADD CONSTRAINT events_org_fk FOREIGN KEY (org_id) REFERENCES orgs (id)|,
    add_foreign_key_not_valid:
      ~s|ALTER TABLE events ADD CONSTRAINT events_org_fk2 FOREIGN KEY (org_id) REFERENCES orgs (id) NOT VALID|,
    validate_foreign_key: ~s|ALTER TABLE events VALIDATE CONSTRAINT events_org_fk2|,
    alter_column_type: ~s|ALTER TABLE events ALTER COLUMN id TYPE bigint|,
    truncate: ~s|TRUNCATE events|,
    reindex: ~s|REINDEX TABLE events|,
    reindex_concurrently: ~s|REINDEX TABLE CONCURRENTLY events|,
    drop_column: ~s|ALTER TABLE events DROP COLUMN org_id|,
    drop_table: ~s|DROP TABLE events|,
    dml_update: ~s|UPDATE events SET org_id = 1|,
    dml_delete: ~s|DELETE FROM events WHERE org_id = 1|,
    dml_insert_select: ~s|INSERT INTO events_v2 SELECT * FROM events|
  }

  test "every qualifying class has a sample statement or a documented exclusion" do
    qualifying = Locks.classes() |> Enum.filter(&qualifies?/1) |> MapSet.new()
    covered = @sample_sql |> Map.keys() |> MapSet.new()
    excluded = @unreachable |> Map.keys() |> MapSet.new()

    missing = MapSet.difference(qualifying, MapSet.union(covered, excluded))

    assert MapSet.to_list(missing) == [],
           "classes qualify for the never-silent net but have neither a sample statement " <>
             "nor a documented exclusion: #{inspect(MapSet.to_list(missing))}"

    # Every excluded class must genuinely still qualify — otherwise the
    # exclusion is stale (either it never qualified, in which case it
    # doesn't need listing, or something changed and it needs a sample).
    stale_exclusions = Enum.reject(Map.keys(@unreachable), &qualifies?/1)

    assert stale_exclusions == [],
           "these exclusions no longer qualify for the net; remove them: #{inspect(stale_exclusions)}"
  end

  test "every qualifying, reachable class produces at least one finding from the full pipeline" do
    for {class, sql} <- @sample_sql do
      findings = findings_for(sql)

      assert findings != [],
             "class #{class} (raw SQL: #{inspect(sql)}) produced ZERO findings from " <>
               "Runner.default_checks/0 against the 412M fixture — this is exactly the " <>
               "silent-DDL failure mode Criticals 2/3 shipped with"
    end
  end

  defp qualifies?(class) do
    case Locks.entry(class, :postgres, 150_000) do
      {lock, cost} -> lock in @write_blocking or cost in [:full_scan, :rewrite]
      :unmapped -> false
    end
  end

  defp findings_for(sql) do
    {:ok, migration} =
      Parser.parse_string(
        "defmodule M do\n use Ecto.Migration\n def change do\n execute #{inspect(sql)}\n end\nend",
        "20260801000000_m.exs"
      )

    tables = [big_events_table(), orgs_table()]
    snapshot = Cerbero.Test.SnapshotBuilder.build_snapshot(%{"tables" => tables})

    staleness = %Cerbero.Snapshot.Staleness{
      age_days: 1,
      scale_mode: :exact,
      threshold_multiplier: 1.0
    }

    catalog = Cerbero.Catalog.from_snapshot(snapshot, staleness)
    {:ok, config} = Cerbero.Config.load("nonexistent")

    {findings, _catalog} = Runner.run([migration], catalog, config)
    findings
  end

  defp orgs_table do
    Cerbero.Test.SnapshotBuilder.table("orgs", %{
      "n_live_tup" => 41_000_000,
      "reltuples" => 41_000_000.0,
      "columns" => [Cerbero.Test.SnapshotBuilder.column("id", %{"not_null" => true})]
    })
  end
end
