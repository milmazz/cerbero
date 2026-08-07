defmodule Cerbero.CLI.GenConfig do
  @moduledoc """
  argv for mix cerbero.gen.config: `--out` (default `.cerbero.exs`), `--force`.

  Writes a config file populated with the built-in defaults so every setting
  is visible in one place; deleting a line falls back to the same default.
  An existing file is never clobbered without `--force` (exit 2).
  """

  @switches [out: :string, force: :boolean]

  @template """
  # Cerbero configuration — evaluates to a keyword list.
  # Every value below is the built-in default: delete a line and cerbero
  # behaves the same. Reference: Cerbero.Config.
  [
    # Table-scale thresholds. A migration touching a table at or past
    # rows_warning escalates to warning, past rows_error (or bytes_error,
    # 1 GiB) to error.
    rows_warning: 100_000,
    rows_error: 1_000_000,
    bytes_error: 1_073_741_824,

    # A table is treated as hot once its catalog traffic reaches this many
    # operations per second.
    hot_ops_per_sec: 1.0,

    # Days between deploys. An applied-but-unsnapshotted migration gets this
    # many days of grace before being flagged.
    deploy_cadence: 1,

    # Snapshot aging: after headroom_days, scale thresholds are tightened by
    # headroom_multiplier to allow for growth since the export; past
    # stale_warn_days the snapshot itself is flagged, past stale_degrade_days
    # its scale data is no longer trusted.
    headroom_days: 14,
    headroom_multiplier: 0.5,
    stale_warn_days: 30,
    stale_degrade_days: 90,

    # Lowest finding severity that makes mix cerbero.check exit 1
    # (:error | :warning | :info).
    fail_on: :error,

    # Check ids to skip entirely, e.g. [:unsafe_index_creation].
    skip_checks: [],

    # Third-party check modules implementing the Cerbero.Check behaviour,
    # run after the built-in checks.
    extra_checks: [],

    # Force a severity per check id, e.g. %{unsafe_index_creation: :info}.
    severity_overrides: %{},

    # Set true to attest that migrations run with a lock_timeout configured.
    lock_timeout_attested: false,

    # Emit info findings even for concurrent index work deemed safe.
    strict_concurrent_index: false,

    # Ignore migrations with versions at or below this value (nil checks all).
    start_after: nil,

    # Snapshot export precision (:exact | :order_of_magnitude).
    precision: :exact,

    # Database schemas the snapshot exporter reads.
    schemas: ["public"],

    # Where migrations live and where the committed snapshot is stored.
    migrations_paths: ["priv/repo/migrations"],
    snapshot_path: "priv/repo/cerbero_snapshot.json",

    # Umbrella apps with several Ecto repos: one entry per repo, e.g.
    # [name: "app_a", migrations_paths: ["apps/app_a/priv/repo/migrations"],
    #  snapshot_path: "apps/app_a/priv/repo/cerbero_snapshot.json"].
    # mix cerbero.check then runs every repo (or one via --repo NAME);
    # all other settings stay global.
    repos: []
  ]
  """

  @spec run([String.t()], keyword()) :: 0 | 2
  def run(argv, opts \\ []) do
    io = Keyword.get(opts, :io, :stdio)

    case OptionParser.parse(argv, strict: @switches) do
      {parsed, [], []} ->
        write(parsed[:out] || ".cerbero.exs", parsed[:force] || false, io)

      {_, _, invalid} ->
        error(io, "invalid options: #{inspect(invalid)}")
    end
  end

  defp write(out, force, io) do
    if File.exists?(out) and not force do
      error(io, "#{out} already exists (pass --force to overwrite)")
    else
      File.write!(out, @template)
      IO.write(io, "cerbero: wrote #{out}\n")
      0
    end
  end

  defp error(io, reason) do
    IO.write(io, "cerbero: error: #{reason}\n")
    2
  end
end
