defmodule Cerbero.CLI.Check do
  @moduledoc "argv -> findings -> formatted output -> exit code. Injectable clock and IO."

  alias Cerbero.Catalog
  alias Cerbero.Check.Runner
  alias Cerbero.Check.SnapshotHealth
  alias Cerbero.CLI.Format
  alias Cerbero.Config
  alias Cerbero.Finding
  alias Cerbero.Migration.Parser
  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Staleness

  @switches [
    snapshot: :string,
    migrations: :string,
    config: :string,
    format: :string,
    fail_on: :string,
    no_snapshot: :boolean,
    down: :boolean,
    repo: :string,
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
         {:ok, fail_on} <- fail_on(parsed, config),
         {:ok, mode} <- run_mode(parsed, config) do
      case mode do
        {:single, config} -> run_single(parsed, config, fail_on, clock)
        {:multi, repos, config} -> run_multi(parsed, config, repos, fail_on, clock)
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # Multi-repo (umbrella) dispatch: `repos` in .cerbero.exs defines one
  # entry per Ecto repo; --repo selects one, no --repo runs them all.
  # Explicit --migrations/--snapshot keep meaning "exactly this path" and
  # bypass the repo table entirely.
  defp run_mode(parsed, config) do
    case {parsed[:repo], config.repos} do
      {nil, []} ->
        {:ok, {:single, config}}

      {nil, repos} ->
        if parsed[:migrations] || parsed[:snapshot] do
          {:ok, {:single, config}}
        else
          {:ok, {:multi, repos, config}}
        end

      {name, []} ->
        {:error, "--repo #{name}: no repos configured in .cerbero.exs"}

      {name, repos} ->
        case Enum.find(repos, &(&1.name == name)) do
          nil ->
            {:error, "unknown repo #{name} (configured: #{Enum.map_join(repos, ", ", & &1.name)})"}

          repo ->
            {:ok, {:single, apply_repo(config, repo)}}
        end
    end
  end

  defp apply_repo(config, repo) do
    %{
      config
      | migrations_paths: repo.migrations_paths,
        snapshot_path: repo.snapshot_path,
        repos: []
    }
  end

  defp run_single(parsed, config, fail_on, clock) do
    with {:ok, migrations} <- parse_migrations(parsed, config),
         {:ok, result} <- collect(parsed, config, migrations, clock) do
      render(
        parsed,
        result.findings,
        result.summary_line,
        result.summary,
        fail_on,
        result.snapshot_path
      )
    end
  end

  defp run_multi(parsed, config, repos, fail_on, clock) do
    results =
      Enum.reduce_while(repos, {:ok, []}, fn repo, {:ok, acc} ->
        repo_config = apply_repo(config, repo)

        with {:ok, migrations} <- parse_migrations(parsed, repo_config),
             {:ok, result} <- collect(parsed, repo_config, migrations, clock) do
          {:cont, {:ok, [{repo, result} | acc]}}
        else
          {:error, reason} -> {:halt, {:error, "repo #{repo.name}: #{reason}"}}
        end
      end)

    with {:ok, per_repo} <- results do
      per_repo = Enum.reverse(per_repo)

      # Global (file-less) findings anchor to their repo's snapshot
      # artifact before the merge, so merged human/sarif output stays
      # attributable to a repo instead of floating free.
      findings =
        Enum.flat_map(per_repo, fn {_repo, r} ->
          Enum.map(r.findings, &anchor_global(&1, r.snapshot_path))
        end)

      summary_line =
        Enum.map_join(per_repo, "\n", fn {repo, r} -> "#{repo.name}: #{r.summary_line}" end)

      summary = %{
        "errors" => count(findings, :error),
        "warnings" => count(findings, :warning),
        "infos" => count(findings, :info),
        "snapshot" => nil,
        "repos" => Map.new(per_repo, fn {repo, r} -> {repo.name, r.summary["snapshot"]} end)
      }

      render(parsed, findings, summary_line, summary, fail_on, nil)
    end
  end

  defp anchor_global(%Finding{file: nil} = finding, snapshot_path) when snapshot_path != nil,
    do: %{finding | file: snapshot_path}

  defp anchor_global(finding, _snapshot_path), do: finding

  defp collect(parsed, config, migrations, clock) do
    if parsed[:no_snapshot] do
      structural(parsed, config, migrations)
    else
      with_snapshot(parsed, config, migrations, clock)
    end
  end

  # Rollbacks are deploys too: with --down, each pending migration's down
  # body is judged against the catalog as the pending ups leave it — the
  # state a rollback actually starts from. (Approximation: downs are
  # judged in version order against that one post-up state, not unwound
  # one at a time.)
  defp down_findings(parsed, pending, catalog_after_up, config) do
    if parsed[:down] do
      down_pending =
        pending
        |> Enum.filter(&(&1.down_operations != []))
        |> Enum.map(&%{&1 | operations: &1.down_operations})

      {findings, _catalog} = Runner.run(down_pending, catalog_after_up, config)
      Enum.map(findings, &%{&1 | message: "[down] " <> &1.message})
    else
      []
    end
  end

  defp load_config(parsed) do
    Config.load(parsed[:config] || ".cerbero.exs")
  end

  defp parse_migrations(parsed, config) do
    with {:ok, dir} <- migrations_dir(parsed, config),
         :ok <- ensure_directory(dir),
         {:ok, migrations} <- Parser.parse_dir(dir) do
      {:ok, migrations}
    else
      {:error, {path, reason}} -> {:error, "cannot parse #{path}: #{inspect(reason)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp migrations_dir(parsed, config) do
    case parsed[:migrations] do
      nil -> first_migrations_path(config.migrations_paths)
      dir -> {:ok, dir}
    end
  end

  defp first_migrations_path([dir | _]) when is_binary(dir), do: {:ok, dir}

  defp first_migrations_path(_), do: {:error, "config migrations_paths is empty; pass --migrations or fix .cerbero.exs"}

  defp ensure_directory(dir) do
    if File.dir?(dir), do: :ok, else: {:error, "migrations directory not found: #{dir}"}
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

  defp with_snapshot(parsed, config, migrations, clock) do
    case Snapshot.load(parsed[:snapshot] || config.snapshot_path,
           verify_keys: config.snapshot_verify_keys
         ) do
      {:error, reason} ->
        {:error, "snapshot: #{inspect(reason)}"}

      {:ok, snapshot} ->
        judge_with_snapshot(snapshot, parsed, config, migrations, clock)
    end
  end

  defp judge_with_snapshot(snapshot, parsed, config, migrations, clock) do
    staleness = Staleness.assess(snapshot, clock.(), config)
    catalog = Catalog.from_snapshot(snapshot, staleness)
    pending = Runner.select_pending(migrations, snapshot.applied_migrations, config.start_after)

    health =
      snapshot
      |> SnapshotHealth.run_global(staleness, migrations, pending, catalog, config)
      |> Runner.apply_policies(SnapshotHealth.id(), config)

    {findings, catalog_after_up} = Runner.run(pending, catalog, config)
    findings = health ++ findings ++ down_findings(parsed, pending, catalog_after_up, config)

    summary_line =
      "judged against snapshot of #{snapshot.database}, " <>
        "#{DateTime.to_date(snapshot.collected_at)}, #{staleness.age_days} days old" <>
        if(snapshot.precision == :order_of_magnitude,
          do: " (order-of-magnitude precision)",
          else: ""
        )

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

    {:ok,
     %{
       findings: findings,
       summary_line: summary_line,
       summary: summary,
       snapshot_path: parsed[:snapshot] || config.snapshot_path
     }}
  end

  defp structural(parsed, config, migrations) do
    {history, pending} =
      Enum.split_with(migrations, fn m ->
        config.start_after != nil and m.version != nil and m.version <= config.start_after
      end)

    catalog = Enum.reduce(history, Catalog.empty(), &Catalog.apply_migration(&2, &1))
    {findings, catalog_after_up} = Runner.run(pending, catalog, config)
    findings = findings ++ down_findings(parsed, pending, catalog_after_up, config)

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

    {:ok, %{findings: findings, summary_line: summary_line, summary: summary, snapshot_path: nil}}
  end

  defp render(parsed, findings, summary_line, summary, fail_on, snapshot_path) do
    output =
      case parsed[:format] || "human" do
        "human" -> Format.Human.render(findings, summary_line, parsed[:verbose] || false)
        "json" -> Format.JSON.render(findings, summary)
        "sarif" -> Format.SARIF.render(findings, summary, snapshot_path)
        other -> {:error, "invalid --format: #{other}"}
      end

    with out when is_binary(out) <- output do
      exit_code = if Enum.any?(findings, &Finding.at_least?(&1.severity, fail_on)), do: 1, else: 0
      {:ok, out, exit_code}
    end
  end

  defp count(findings, severity), do: Enum.count(findings, &(&1.severity == severity))
end
