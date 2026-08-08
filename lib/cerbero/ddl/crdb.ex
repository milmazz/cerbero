defmodule Cerbero.DDL.CRDB do
  @moduledoc """
  CockroachDB limitation table, keyed by class and version. Same
  data-not-conditionals rigor as Locks. Scoped to the facts rules 4 and 7
  consume; layer 4 asserts the observable behaviors behind it.
  """

  @doc """
  :online — succeeds as an online schema change;
  {:limited, note} — succeeds with a caveat worth a finding;
  {:rejected, note} — the engine refuses it; cerbero errors BEFORE deploy fails.
  """
  @spec judge(atom(), integer()) :: :online | {:limited, String.t()} | {:rejected, String.t()}

  # Layer 4 (empirical, CockroachDB v25.1.10): this was previously
  # {:rejected, "...rejects ALTER COLUMN TYPE on a column used by an
  # index, constraint, or computed column"}. Verified false on a live
  # v25.1 node — ALTER COLUMN TYPE succeeds (via CRDB's validate/backfill
  # schema-change job) on a secondary-indexed column, a PRIMARY KEY
  # column, a CHECK-constrained column, and an FK-constrained column,
  # in every case tried, as long as the target type is data-compatible
  # (`STRING`->`VARCHAR(n)`, `INT`->`INT8`). The one case that still
  # reproducibly fails is different from all of those: a column type
  # cannot be changed while some *other*, separate computed/generated
  # column in the table depends on it ("cannot alter type of column ...
  # because computed column ... depends on it", SQLSTATE 2BP01) — the
  # call site's `generated_siblings/3` scan names that mechanism when the
  # snapshot shows a candidate column. Downgraded to `:limited`
  # rather than deleted: the sole call site
  # (`Cerbero.Check.ColumnTypeChange.crdb_judge/6`) previously branched
  # on `{:rejected, _}` vs. everything else, and its `_` branch already
  # emitted an accurate, still-true :warning (ALTER COLUMN TYPE can't run
  # inside an explicit multi-statement transaction on CRDB) — this
  # correction made that `{:rejected, _}` clause provably unreachable
  # (Elixir's type checker flagged it), so it and the now-dead
  # `indexed?`/`constrained?`/`generated_stored?` detection that fed it
  # were removed there; see that module's moduledoc for the follow-up.
  # Not version-gated: only v25.1 was available to verify against, so
  # this note doesn't claim when the behavior changed, only that it has.
  def judge(:alter_column_type_indexed, _v),
    do:
      {:limited,
       "CockroachDB (verified v25.1) allows ALTER COLUMN TYPE on indexed, PK, or constrained " <>
         "columns when the new type is data-compatible; it still rejects the change when a " <>
         "separate computed/generated column elsewhere in the table depends on this column"}

  def judge(:alter_column_type_in_txn, _v),
    do: {:rejected, "CockroachDB rejects ALTER COLUMN TYPE inside an explicit transaction with other statements"}

  def judge(:multiple_ddl_in_txn, _v),
    do: {:limited, "multiple schema changes in one transaction are restricted; failed changes cannot roll back cleanly"}

  def judge(:create_index, _v),
    do: {:limited, "index builds are online but consume foreground cluster resources at scale"}

  def judge(_class, _v), do: :online
end
