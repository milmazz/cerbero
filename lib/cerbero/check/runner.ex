defmodule Cerbero.Check.Runner do
  @moduledoc "Orders pending migrations, threads the overlay, applies skips and severity overrides."

  alias Cerbero.{Catalog, Config, Finding, Migration}

  @spec default_checks() :: [module()]
  def default_checks do
    [
      Cerbero.Check.MetaFindings
      # Rules append themselves here as their tasks land (Tasks 11-15).
    ]
  end

  @spec select_pending([Migration.t()], [String.t()], String.t() | nil) :: [Migration.t()]
  def select_pending(migrations, applied_versions, start_after) do
    applied = MapSet.new(applied_versions)

    migrations
    |> Enum.reject(&MapSet.member?(applied, &1.version))
    |> Enum.reject(fn m -> start_after != nil and m.version <= start_after end)
    |> Enum.sort_by(& &1.version)
  end

  @spec run([Migration.t()], Catalog.t(), Config.t(), [module()]) :: {[Finding.t()], Catalog.t()}
  def run(pending, %Catalog{} = catalog, %Config{} = config, checks \\ default_checks()) do
    {findings, final_catalog} =
      Enum.map_reduce(pending, catalog, fn migration, cat ->
        findings =
          checks
          |> Enum.reject(&(&1.id() in config.skip_checks))
          |> Enum.flat_map(& &1.run(migration, cat, config))
          |> Enum.map(&apply_skip(&1, migration))
          |> Enum.map(&apply_override(&1, config))

        {findings, Catalog.apply_migration(cat, migration)}
      end)

    {List.flatten(findings), final_catalog}
  end

  defp apply_skip(%Finding{} = finding, %Migration{attrs: %{cerbero_skip: skips}}) do
    case List.keyfind(skips, finding.check, 0) do
      {_, reason} ->
        %{finding | severity: :info, message: finding.message <> " (skipped: #{reason})"}

      nil ->
        finding
    end
  end

  defp apply_override(%Finding{} = finding, %Config{severity_overrides: overrides}) do
    case Map.fetch(overrides, finding.check) do
      {:ok, severity} -> %{finding | severity: severity}
      :error -> finding
    end
  end
end
