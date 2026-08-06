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
  def judge(:alter_column_type_indexed, _v),
    do:
      {:rejected,
       "CockroachDB rejects ALTER COLUMN TYPE on a column used by an index, constraint, or computed column"}

  def judge(:alter_column_type_in_txn, _v),
    do:
      {:rejected,
       "CockroachDB rejects ALTER COLUMN TYPE inside an explicit transaction with other statements"}

  def judge(:multiple_ddl_in_txn, _v),
    do:
      {:limited,
       "multiple schema changes in one transaction are restricted; failed changes cannot roll back cleanly"}

  def judge(:create_index, _v),
    do: {:limited, "index builds are online but consume foreground cluster resources at scale"}

  def judge(_class, _v), do: :online
end
