defmodule Cerbero.Check.MetaFindings do
  @moduledoc """
  The escape routes for the worst migrations must be reachable by
  --fail-on: unclassified SQL, unknown operations, and unmapped lock
  entries all warn by default, never silence.
  """
  @behaviour Cerbero.Check

  alias Cerbero.Check.Helpers
  alias Cerbero.DDL.Effects
  alias Cerbero.Operation, as: Op

  @impl true
  def id, do: :meta_findings

  @impl true
  def run(migration, catalog, _config) do
    Enum.flat_map(migration.operations, fn
      %Op.RawSQL{classified: classified, line: line} = op ->
        if Enum.any?(classified, &(&1.class == :unknown)) do
          [
            %{
              Helpers.finding(
                __MODULE__,
                :warning,
                "cerbero cannot judge this SQL — unclassifiable statement; " <>
                  "review manually or add @cerbero_skip with a reason",
                migration,
                line
              )
              | check: :unclassified_sql
            }
          ]
        else
          unmapped_findings(op, migration, catalog)
        end

      %Op.Unknown{line: line, description: desc} ->
        [
          %{
            Helpers.finding(
              __MODULE__,
              :warning,
              "cerbero cannot judge this operation (dynamically constructed): #{desc}",
              migration,
              line
            )
            | check: :unknown_operation
          }
        ]

      op ->
        unmapped_findings(op, migration, catalog)
    end)
  end

  defp unmapped_findings(op, migration, catalog) do
    op
    |> Effects.derive(catalog.engine, catalog.version_num)
    |> Enum.filter(& &1.unmapped)
    |> Enum.reject(&(&1.class in [:unknown_operation, :unclassified_sql]))
    |> Enum.map(fn effect ->
      %{
        Helpers.finding(
          __MODULE__,
          :warning,
          "operation class #{effect.class} has no lock-table entry; " <>
            "judged conservatively as ACCESS EXCLUSIVE + rewrite",
          migration,
          effect.line,
          # The conservative default claims ACCESS EXCLUSIVE in its message;
          # carrying effect.lock keeps the attestation annotation honest.
          metadata: %{lock: effect.lock}
        )
        | check: :unmapped_operation
      }
    end)
  end
end
