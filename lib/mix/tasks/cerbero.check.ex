defmodule Mix.Tasks.Cerbero.Check do
  @shortdoc "Judge pending migrations against the committed cerbero snapshot"
  @moduledoc """
  Parse pending Ecto migrations (static AST — your code never runs), fold
  their effects into the catalog model recorded by `mix cerbero.snapshot`,
  and judge each operation by lock mode × cost class × your production scale
  and traffic. Meant to run in CI, where no database is reachable: the exit
  code is the verdict.

  ## Options

    * `--config PATH` — config file to load (default `.cerbero.exs`).
    * `--snapshot PATH` — snapshot to judge against (default
      `config.snapshot_path`). Verified against `config.snapshot_verify_keys`
      when set.
    * `--migrations DIR` — migrations directory (default the first entry of
      `config.migrations_paths`).
    * `--fail-on error|warning|info` — lowest severity that makes the task
      exit 1 (default `config.fail_on`, itself `:error`).
    * `--format human|json|sarif` — output format (default `human`).
      `sarif` suits code-scanning dashboards; `json` suits scripting.
    * `--no-snapshot` — skip the snapshot and run structural checks only;
      every finding is tagged "scale unknown". Useful before a first
      snapshot exists.
    * `--down` — also judge each pending migration's rollback (`down`) body
      against the catalog the pending `up`s leave behind. Rollbacks are
      deploys too.
    * `--repo NAME` — in an umbrella with `config.repos`, check only that
      repo. Without it every configured repo is checked.
    * `--verbose` — expand `human` output.

  ## Examples

      # Standard CI invocation
      mix cerbero.check

      # SARIF for a code-scanning dashboard, failing on warnings too
      mix cerbero.check --format sarif --fail-on warning > cerbero.sarif

      # Judge rollbacks as well; check one umbrella repo
      mix cerbero.check --down --repo billing

  ## Exit codes

    * `0` — clean: no finding at or above the `--fail-on` threshold.
    * `1` — at least one finding at or above the threshold.
    * `2` — operational error (missing/invalid snapshot or migrations
      directory, bad config, unparseable migration, invalid flag value).

  Implemented by `Cerbero.CLI.Check`.
  """
  use Mix.Task

  @impl true
  def run(argv) do
    case Cerbero.CLI.Check.run(argv) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end
end
