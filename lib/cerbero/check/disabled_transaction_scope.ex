defmodule Cerbero.Check.DisabledTransactionScope do
  @moduledoc """
  A migration with `@disable_ddl_transaction` runs without a transaction, so a
  partial failure cannot be rolled back and the whole migration is re-run from
  the top. It must therefore contain only operations that genuinely require a
  disabled transaction: concurrent index create/drop, and — as raw SQL —
  `ALTER TYPE ... ADD VALUE` and `ANALYZE` (both classify as `:unknown`, so
  `Cerbero.Check.MetaFindings` already surfaces them; this rule leaves them
  alone rather than double-flagging).

  Any other, transactional operation here forfeits the rollback safety net for
  no reason and, mixed with a concurrent step, wedges the deploy on re-run. The
  classic failure shape is a concurrent index alongside a `create table`: the
  index step fails, and the re-run dies on the already-created table. Move it to
  a separate migration that runs inside a transaction.

  Structural rule: no snapshot needed, so it runs in `--no-snapshot` mode too.
  The complement of Rule 10 (`ConcurrentIndexRequiresAttributes`), which checks
  the forward direction — `concurrently: true` *requires* the attribute; this
  checks the reverse — the attribute permits only a small set of operations.
  Because cerbero's parser does not track the idempotent `*_if_not_exists` forms
  (`create` and `create_if_not_exists` parse to the same op), this rule cannot
  reproduce the Credo check's idempotent-form exemption; it is instead stricter
  and simpler — nothing transactional belongs in a disabled-transaction migration
  regardless of re-runnability.
  """
  @behaviour Cerbero.Check

  alias Cerbero.Check.Helpers
  alias Cerbero.Operation, as: Op
  alias Cerbero.SQL.Classifier.Classified

  @impl true
  def id, do: :disabled_transaction_scope

  @impl true
  def description,
    do: "@disable_ddl_transaction limits a migration to concurrent index create/drop and re-runnable raw SQL"

  @impl true
  def run(%{attrs: %{disable_ddl_transaction: false}}, _catalog, _config), do: []

  def run(migration, _catalog, _config) do
    for op <- migration.operations, {line, what} <- disallowed(op) do
      Helpers.finding(__MODULE__, :warning, message(what), migration, line)
    end
  end

  # Concurrent index create/drop legitimately require the disabled transaction.
  defp disallowed(%Op.CreateIndex{concurrently: true}), do: []
  defp disallowed(%Op.DropIndex{concurrently: true}), do: []

  defp disallowed(%Op.CreateIndex{concurrently: false, line: line}), do: [{line, "a non-concurrent index creation"}]
  defp disallowed(%Op.DropIndex{concurrently: false, line: line}), do: [{line, "a non-concurrent index drop"}]
  defp disallowed(%Op.CreateTable{line: line}), do: [{line, "a create table"}]
  defp disallowed(%Op.DropTable{line: line}), do: [{line, "a drop table"}]
  defp disallowed(%Op.AlterTable{line: line}), do: [{line, "an alter table (add/modify/remove column)"}]
  defp disallowed(%Op.CreateConstraint{line: line}), do: [{line, "a constraint creation"}]
  defp disallowed(%Op.RenameOp{line: line}), do: [{line, "a rename"}]

  # Raw SQL: only concurrent index/reindex is allowed. `:unknown` is left to
  # MetaFindings (it may be the legitimate ALTER TYPE ADD VALUE / ANALYZE, which
  # the classifier does not recognize); any other classified statement is
  # transactional DDL that does not belong here.
  defp disallowed(%Op.RawSQL{classified: classified, line: line}) do
    for %Classified{class: class} = c <- classified, not allowed_sql?(c), do: {line, "a raw #{class} statement"}
  end

  # Unknown (dynamically-built) operations are surfaced by MetaFindings; do not
  # double-flag them here.
  defp disallowed(_op), do: []

  defp allowed_sql?(%Classified{class: :create_index, concurrently: concurrently}), do: concurrently
  defp allowed_sql?(%Classified{class: :drop_index, concurrently: concurrently}), do: concurrently
  defp allowed_sql?(%Classified{class: :reindex, concurrently: concurrently}), do: concurrently
  defp allowed_sql?(%Classified{class: :unknown}), do: true
  defp allowed_sql?(%Classified{}), do: false

  defp message(what) do
    "#{what} is not safe in a migration with @disable_ddl_transaction: without a transaction a " <>
      "partial failure cannot be rolled back and the migration is re-run from the top, so mixing " <>
      "it with a concurrent step can wedge the deploy. Move it to a separate " <>
      "migration that runs inside a transaction — @disable_ddl_transaction is only for concurrent " <>
      "index create/drop, ALTER TYPE ... ADD VALUE, and ANALYZE."
  end
end
