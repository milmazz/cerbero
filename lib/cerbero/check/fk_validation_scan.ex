defmodule Cerbero.Check.FKValidationScan do
  @moduledoc "Rule 5: ADD FK scans the referencing table while blocking writes on BOTH tables."
  @behaviour Cerbero.Check

  alias Cerbero.Catalog
  alias Cerbero.Check.Helpers
  alias Cerbero.Check.Judgment
  alias Cerbero.DDL.Effects

  @impl true
  def id, do: :fk_validation_scan

  @impl true
  def description, do: "ADD FOREIGN KEY scans the referencing table while blocking writes on the referenced table"

  @impl true
  def run(migration, catalog, config) do
    # Skip CRDB: FK adds are online schema changes
    if catalog.engine == :cockroachdb do
      []
    else
      Helpers.fold_operations(migration, catalog, fn op, cat ->
        op
        |> Effects.derive(cat.engine, cat.version_num)
        |> Enum.filter(&(&1.class == :add_foreign_key))
        |> Enum.flat_map(fn effect ->
          # Skip FKs with validate: false (add_foreign_key_not_valid) — they don't trigger a scan
          referencing = Keyword.get(effect.relations, :target)
          referenced = Keyword.get(effect.relations, :referenced)
          judge_scan(referencing, referenced, effect.line, migration, cat, config)
        end)
      end)
    end
  end

  defp judge_scan(referencing, referenced, line, migration, catalog, config) do
    q_ing = Catalog.qualify(referencing)
    q_ed = referenced && Catalog.qualify(referenced)

    Judgment.judge(
      __MODULE__,
      %{table: referencing, lock: :share_row_exclusive, cost: :full_scan, line: line},
      migration,
      catalog,
      config,
      # Both tables' scale matters: the referenced side's writes are blocked
      # while the referencing side is scanned. When referenced is unknown
      # (nil), severity comes from the referencing table alone.
      also_assess: [referenced],
      relations: Enum.reject([q_ing, q_ed], &is_nil/1),
      severity: fn
        severity when severity in [:error, :warning] -> severity
        _ -> :suppress
      end,
      message: fn -> scan_message(q_ing, q_ed, referencing, referenced, catalog) end
    )
  end

  defp scan_message(q_ing, q_ed, referencing, referenced, catalog) do
    partitioned = match?(%{partitioned: true}, Catalog.table(catalog, referencing))

    not_valid_supported =
      not (partitioned and catalog.engine == :postgres and catalog.version_num < 180_000)

    remediation =
      if not_valid_supported do
        "add the FK with validate: false (NOT VALID), then VALIDATE CONSTRAINT in a later migration " <>
          "(SHARE UPDATE EXCLUSIVE, writes continue)"
      else
        "NOT VALID foreign keys on partitioned referencing tables require PG 18; " <>
          "below that, schedule the validation scan for a maintenance window"
      end

    if q_ed do
      "ADD FOREIGN KEY: writes to #{q_ed} (#{Helpers.describe_scale(catalog, referenced)}) are blocked " <>
        "while #{q_ing} (#{Helpers.describe_scale(catalog, referencing)}) is scanned " <>
        "(SHARE ROW EXCLUSIVE on both). " <> remediation
    else
      "ADD FOREIGN KEY: #{q_ing} (#{Helpers.describe_scale(catalog, referencing)}) is scanned " <>
        "under SHARE ROW EXCLUSIVE (referenced table unknown). " <> remediation
    end
  end
end
