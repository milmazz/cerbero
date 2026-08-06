defmodule Cerbero.CLI.Check do
  @moduledoc "argv -> findings -> formatted output -> exit code. Injectable clock and IO."

  alias Cerbero.{Catalog, Config, Finding, Snapshot}
  alias Cerbero.Check.{Runner, SnapshotHealth}
  alias Cerbero.CLI.Format
  alias Cerbero.Migration.Parser
  alias Cerbero.Snapshot.Staleness

  @switches [
    snapshot: :string,
    migrations: :string,
    config: :string,
    format: :string,
    fail_on: :string,
    no_snapshot: :boolean,
    verbose: :boolean
  ]

  @spec run([String.t()], keyword()) :: 0 | 1 | 2
  def run(argv, opts \\ []) do
    io = Keyword.get(opts, :io, :stdio)
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    case do_run(argv, clock) do
      {:ok, output, exit_code} ->
        IO.write(io, output)
        exit_code

      {:error, message} ->
        IO.write(io, "cerbero: error: #{message}\n")
        2
    end
  end

  defp do_run(argv, clock) do
    case OptionParser.parse(argv, strict: @switches) do
      {parsed, [], []} -> do_run_parsed(Map.new(parsed), clock)
      {_, _, invalid} -> {:error, "invalid options: #{inspect(invalid)}"}
    end
  end

  defp do_run_parsed(parsed, clock) do
    with {:ok, config} <- load_config(parsed),
         {:ok, migrations} <- parse_migrations(parsed, config),
         {:ok, fail_on} <- fail_on(parsed, config) do
      if parsed[:no_snapshot] do
        structural(parsed, config, migrations, fail_on)
      else
        with_snapshot(parsed, config, migrations, fail_on, clock)
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp load_config(parsed) do
    Config.load(parsed[:config] || ".cerbero.exs")
  end

  defp parse_migrations(parsed, config) do
    dir = parsed[:migrations] || hd(config.migrations_paths)

    case Parser.parse_dir(dir) do
      {:ok, migrations} -> {:ok, migrations}
      {:error, {path, reason}} -> {:error, "cannot parse #{path}: #{inspect(reason)}"}
    end
  end

  defp fail_on(parsed, config) do
    case parsed[:fail_on] do
      nil -> {:ok, config.fail_on}
      "error" -> {:ok, :error}
      "warning" -> {:ok, :warning}
      "info" -> {:ok, :info}
      other -> {:error, "invalid --fail-on: #{other}"}
    end
  end

  defp with_snapshot(parsed, config, migrations, fail_on, clock) do
    with {:ok, snapshot} <- Snapshot.load(parsed[:snapshot] || config.snapshot_path) do
      staleness = Staleness.assess(snapshot, clock.(), config)
      catalog = Catalog.from_snapshot(snapshot, staleness)
      pending = Runner.select_pending(migrations, snapshot.applied_migrations, config.start_after)

      health =
        SnapshotHealth.run_global(snapshot, staleness, migrations, pending, catalog, config)

      {findings, _catalog} = Runner.run(pending, catalog, config)
      findings = health ++ findings

      summary_line =
        "judged against snapshot of #{snapshot.database}, " <>
          "#{DateTime.to_date(snapshot.collected_at)}, #{staleness.age_days} days old"

      summary = %{
        "errors" => count(findings, :error),
        "warnings" => count(findings, :warning),
        "infos" => count(findings, :info),
        "snapshot" => %{
          "age_days" => staleness.age_days,
          "collected_at" => DateTime.to_iso8601(snapshot.collected_at),
          "database" => snapshot.database
        }
      }

      render(parsed, findings, summary_line, summary, fail_on)
    else
      {:error, reason} -> {:error, "snapshot: #{inspect(reason)}"}
    end
  end

  defp structural(parsed, config, migrations, fail_on) do
    {history, pending} =
      Enum.split_with(migrations, fn m ->
        config.start_after != nil and m.version != nil and m.version <= config.start_after
      end)

    catalog = Enum.reduce(history, Catalog.empty(), &Catalog.apply_migration(&2, &1))
    {findings, _} = Runner.run(pending, catalog, config)

    findings =
      Enum.map(
        findings,
        &%{&1 | message: &1.message <> " [no snapshot: structural checks only, scale unknown]"}
      )

    summary_line = "no snapshot: structural checks only, scale unknown"

    summary = %{
      "errors" => count(findings, :error),
      "warnings" => count(findings, :warning),
      "infos" => count(findings, :info),
      "snapshot" => nil
    }

    render(parsed, findings, summary_line, summary, fail_on)
  end

  defp render(parsed, findings, summary_line, summary, fail_on) do
    output =
      case parsed[:format] || "human" do
        "human" -> Format.Human.render(findings, summary_line, parsed[:verbose] || false)
        "json" -> Format.JSON.render(findings, summary)
        other -> {:error, "invalid --format: #{other}"}
      end

    with out when is_binary(out) <- output do
      exit_code = if Enum.any?(findings, &Finding.at_least?(&1.severity, fail_on)), do: 1, else: 0
      {:ok, out, exit_code}
    end
  end

  defp count(findings, severity), do: Enum.count(findings, &(&1.severity == severity))
end
