defmodule Cerbero.Check.FKValidationScan do
  @moduledoc "Rule 5: ADD FK scans the referencing table while blocking writes on BOTH tables."
  @behaviour Cerbero.Check

  alias Cerbero.{Catalog, Severity}
  alias Cerbero.Check.Helpers
  alias Cerbero.DDL.Effects

  @impl true
  def id, do: :fk_validation_scan

  @impl true
  def run(migration, catalog, config) do
    migration.operations
    |> Enum.flat_map(&Effects.derive(&1, catalog.engine, catalog.version_num))
    |> Enum.filter(&(&1.class == :add_foreign_key))
    |> Enum.flat_map(fn effect ->
      # Skip FKs with validate: false (add_foreign_key_not_valid) — they don't trigger a scan
      referencing = Keyword.get(effect.relations, :target)
      referenced = Keyword.get(effect.relations, :referenced)
      judge(referencing, referenced, effect.line, migration, catalog, config)
    end)
  end

  defp judge(referencing, referenced, line, migration, catalog, config) do
    scale_ing = Catalog.scale(catalog, referencing)
    scale_ed = if referenced, do: Catalog.scale(catalog, referenced), else: :unknown
    traffic = Catalog.traffic(catalog, referencing, config)

    severity =
      [scale_ing, scale_ed]
      |> Enum.map(
        &Severity.assess(
          :share_row_exclusive,
          :full_scan,
          &1,
          traffic,
          config,
          catalog.multiplier
        )
      )
      |> Enum.max_by(fn s -> %{error: 3, warning: 2, info: 1, none: 0}[s] end)

    if severity in [:error, :warning] do
      q_ing = Catalog.qualify(referencing)
      q_ed = referenced && Catalog.qualify(referenced)

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

      [
        Helpers.finding(
          __MODULE__,
          severity,
          "ADD FOREIGN KEY: writes to #{q_ed} (#{Helpers.describe_scale(catalog, referenced)}) are blocked " <>
            "while #{q_ing} (#{Helpers.describe_scale(catalog, referencing)}) is scanned " <>
            "(SHARE ROW EXCLUSIVE on both). " <> remediation,
          migration,
          line,
          relations: Enum.reject([q_ing, q_ed], &is_nil/1)
        )
      ]
    else
      []
    end
  end
end
