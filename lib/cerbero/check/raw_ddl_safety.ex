defmodule Cerbero.Check.RawDDLSafety do
  @moduledoc """
  Catch-all for classified raw SQL whose class no other rule consumes.

  Classification succeeding is not the same as being judged: a raw
  `ALTER TABLE ... ALTER COLUMN ... TYPE ...`, `TRUNCATE`, `DROP TABLE`, or a
  generic `ADD CONSTRAINT ... CHECK` all classify cleanly and get a correct
  lock/cost from `Cerbero.DDL.Effects.derive/3` — but before this rule
  existed, no check filtered those classes, so they produced zero findings
  while `unclassified_sql` (which only fires when classification itself
  fails) stayed silent too, since classification here *succeeded*.

  This is the general-purpose judge for everything left over: it defers to
  `Cerbero.Severity.assess/6` using the same migration-local fold +
  born-silencing pattern as `unsafe_index_creation.ex`, so it inherits the
  "a write-blocking-lock-taking operation is never silent" floor for free.
  `TRUNCATE` gets an unconditional severity floor of `:error` regardless of
  scale (destructive, irreversible — design §4) on non-born tables.

  Also the judge for the two DSL operations no named rule owns —
  `rename table(...)` and `drop table(...)` — both metadata-only under
  ACCESS EXCLUSIVE, judged through the same generic path (lock-queue note,
  traffic/scale-gated severity, born-silencing).
  """
  @behaviour Cerbero.Check

  alias Cerbero.{Catalog, Severity}
  alias Cerbero.Check.Helpers
  alias Cerbero.DDL.Effects
  alias Cerbero.Operation, as: Op

  @impl true
  def id, do: :raw_ddl_safety

  # Classes a dedicated rule already judges end-to-end for raw SQL — never
  # double-report these. (DSL forms of the same classes are unaffected: this
  # rule never sees DSL operations at all, see moduledoc.)
  #
  #   create_index / add_unique / add_primary_key -> rule 1 (unsafe_index_creation)
  #   set_not_null                                 -> rule 2 (not_null_on_populated_table)
  #   add_column_volatile_default,
  #   add_column_generated_stored                  -> rule 3 (column_default_rewrite)
  #   add_foreign_key                              -> rule 5 (fk_validation_scan)
  #   dml_update / dml_delete / dml_insert_select   -> rule 9 (dml_in_migration)
  #
  # Deliberately NOT here: add_check_not_valid, validate_check,
  # add_foreign_key_not_valid, validate_foreign_key — these are the tool's
  # own recommended two-step "safe" patterns (rule 2's NOT VALID + VALIDATE
  # CONSTRAINT two-step; rule 5's validate: false remediation). They are
  # still judged generically below (never silent for a write-blocking
  # lock — rule 2 sets this precedent itself for the validated-check case:
  # an :info "scan is skipped ... still takes ACCESS EXCLUSIVE briefly" note
  # even on the safe path) but that is an honest brief-lock note, not the
  # false "full scan" claim the two-step exists to avoid.
  #
  # Also NOT here: drop_index / drop_index_concurrently / reindex /
  # reindex_concurrently. Rule 1 filters those classes too, but the raw-SQL
  # forms always carry an empty `relations` (the classifier captures an
  # index name, not a table, for DROP INDEX; nothing at all for REINDEX) —
  # rule 1's `table == nil -> []` guard silently no-ops on them for raw SQL
  # (DSL `drop index(...)` is unaffected; it always has a real target, and
  # this rule never sees DSL ops). This rule is where the raw-SQL forms
  # actually get resolved and judged instead — see `resolve_target/2`.
  @owned MapSet.new(~w(create_index add_unique add_primary_key
              set_not_null
              add_column_volatile_default add_column_generated_stored
              add_foreign_key
              dml_update dml_delete dml_insert_select)a)

  @resolve_classes ~w(drop_index drop_index_concurrently reindex reindex_concurrently)a

  # Mirrors Cerbero.Severity's private list — duplicated rather than
  # exposed; it's three atoms and the alternative is making internals
  # public for a single caller.
  @write_blocking [:access_exclusive, :share, :share_row_exclusive]

  @impl true
  def run(migration, catalog, config) do
    Helpers.fold_operations(migration, catalog, fn op, cat ->
      case op do
        %Op.RawSQL{} -> judge(op, migration, cat, config)
        %Op.RenameOp{} -> judge_dsl(op, migration, cat, config)
        %Op.DropTable{} -> judge_dsl(op, migration, cat, config)
        _ -> []
      end
    end)
  end

  # DSL rename/drop-table: one op -> one effect (AEL + metadata_only per the
  # Locks table); the generic path supplies the lock-queue note, severity
  # gating, and born-silencing.
  defp judge_dsl(op, migration, catalog, config) do
    op
    |> Effects.derive(catalog.engine, catalog.version_num)
    |> Enum.reject(& &1.unmapped)
    |> Enum.flat_map(&generic_judge(&1, migration, catalog, config))
  end

  defp judge(%Op.RawSQL{classified: classified} = op, migration, catalog, config) do
    effects = Effects.derive(op, catalog.engine, catalog.version_num)

    # classify/1 -> sql_class/1 emits exactly one effect per classified
    # statement (see Cerbero.DDL.Effects), so pairing by position holds.
    classified
    |> Enum.zip(effects)
    |> Enum.reject(fn {_c, effect} -> effect.unmapped or effect.class in @owned end)
    |> Enum.flat_map(fn {c, effect} -> judge_effect(c, effect, migration, catalog, config) end)
  end

  defp judge_effect(_c, %{class: :truncate} = effect, migration, catalog, _config) do
    truncate_finding(effect, migration, catalog)
  end

  defp judge_effect(c, %{class: class} = effect, migration, catalog, config)
       when class in @resolve_classes do
    case resolve_target(catalog, c) do
      {:ok, table} ->
        generic_judge(%{effect | relations: [target: table]}, migration, catalog, config)

      :unresolved ->
        unresolved_finding(effect, migration, catalog)
    end
  end

  defp judge_effect(_c, effect, migration, catalog, config) do
    generic_judge(effect, migration, catalog, config)
  end

  # TRUNCATE: destructive and irreversible regardless of table size — the
  # severity floor is :error on any known, non-born table (design §4).
  # Silenced only by born-silencing (create-then-truncate the same table
  # within one pending set is fine: nothing survives to be lost).
  defp truncate_finding(effect, migration, catalog) do
    table = Keyword.get(effect.relations, :target)

    cond do
      table == nil ->
        []

      Catalog.born_empty?(catalog, table) ->
        []

      true ->
        qualified = Catalog.qualify(table)

        [
          Helpers.finding(
            __MODULE__,
            :error,
            "TRUNCATE #{qualified} (#{Helpers.describe_scale(catalog, table)}) is destructive and " <>
              "irreversible — data loss with no partial-rollback story once committed. " <>
              "ACCESS EXCLUSIVE briefly locks the table regardless of size; set a lock_timeout",
            migration,
            effect.line,
            relations: [qualified],
            engine: catalog.engine
          )
        ]
    end
  end

  defp generic_judge(effect, migration, catalog, config) do
    table = Keyword.get(effect.relations, :target)

    cond do
      table == nil ->
        []

      Catalog.born_empty?(catalog, table) ->
        []

      true ->
        qualified = Catalog.qualify(table)
        scale = Catalog.scale(catalog, table)
        traffic = Catalog.traffic(catalog, table, config)

        severity =
          Severity.assess(effect.lock, effect.cost, scale, traffic, config, catalog.multiplier)

        if severity == :none do
          []
        else
          [
            Helpers.finding(
              __MODULE__,
              severity,
              mechanism(effect, qualified, catalog, table),
              migration,
              effect.line,
              relations: [qualified],
              engine: catalog.engine
            )
          ]
        end
    end
  end

  defp mechanism(effect, qualified, catalog, table) do
    scale_desc = Helpers.describe_scale(catalog, table)
    lock_desc = Helpers.lock_name(effect.lock)

    cond do
      effect.lock in @write_blocking and effect.cost in [:full_scan, :rewrite] ->
        "#{lock_desc} lock blocks writes on #{qualified} (#{scale_desc}) for a " <>
          "#{cost_desc(effect.cost)}"

      effect.lock in @write_blocking and effect.cost == :metadata_only ->
        "#{lock_desc} lock on #{qualified} (#{scale_desc}) queues behind long-running queries; " <>
          "set a lock_timeout"

      effect.cost in [:full_scan, :rewrite] ->
        "#{lock_desc} lock on #{qualified} (#{scale_desc}) is non-blocking but the " <>
          "#{cost_desc(effect.cost)} consumes resources at scale"

      true ->
        "#{lock_desc} lock on #{qualified} (#{scale_desc}) from #{effect.class}"
    end
  end

  defp cost_desc(:full_scan), do: "full-table scan"
  defp cost_desc(:rewrite), do: "full-table rewrite"

  defp unresolved_finding(effect, migration, catalog) do
    [
      Helpers.finding(
        __MODULE__,
        :info,
        "cannot resolve the table for this #{describe_class(effect.class)} statement against the " <>
          "snapshot catalog; #{Helpers.lock_name(effect.lock)} on its table regardless of size — " <>
          "set a lock_timeout",
        migration,
        effect.line,
        relations: [],
        engine: catalog.engine
      )
    ]
  end

  defp describe_class(:drop_index), do: "DROP INDEX"
  defp describe_class(:drop_index_concurrently), do: "DROP INDEX CONCURRENTLY"
  defp describe_class(:reindex), do: "REINDEX"
  defp describe_class(:reindex_concurrently), do: "REINDEX CONCURRENTLY"

  # The classifier captures the *index* name into `constraint` for DROP
  # INDEX (never a table — see Cerbero.SQL.Classifier); REINDEX captures no
  # name at all. Resolve by scanning every known table's indexes for a name
  # match; unresolvable (no name captured, or no index in the catalog by
  # that name) falls back to an unowned-but-not-silent note.
  defp resolve_target(_catalog, %{constraint: nil}), do: :unresolved

  defp resolve_target(catalog, %{constraint: index_name}) do
    catalog.tables
    |> Enum.find(fn {_qname, t} -> Enum.any?(t.indexes, &(&1.name == index_name)) end)
    |> case do
      {qname, _t} -> {:ok, qname}
      nil -> :unresolved
    end
  end
end
