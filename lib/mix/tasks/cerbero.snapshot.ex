defmodule Mix.Tasks.Cerbero.Snapshot do
  @shortdoc "Export a cerbero catalog snapshot from a database"
  @moduledoc """
  Export a snapshot of your database's catalog metadata — schema shapes,
  row/byte estimates, traffic counters, index/constraint validity — to a
  canonical, checksummed JSON artifact you commit. `mix cerbero.check`
  judges pending migrations against it. No row data, expression text, or
  literals are ever exported (see the privacy boundary in the README).

  ## Modes (exactly one required)

    * `--url URL` — connect and export live. The engine (PostgreSQL or
      CockroachDB) is detected from the connection.
    * `--emit-sql` — print, without connecting, the read-only SQL script the
      live path would run, for a DBA to run with their own credentials. Pair
      with `--engine` to choose the dialect.
    * `--from-file PATH` — build the snapshot from the output of that emitted
      script. The engine is detected from the file's own sections.

  ## Options

    * `--out PATH` — where to write the snapshot. Defaults to
      `config.snapshot_path` (itself `priv/repo/cerbero_snapshot.json`), so
      the snapshot lands where `mix cerbero.check` reads it.
    * `--config PATH` — config file to load (default `.cerbero.exs`).
      `config.schemas` governs which schemas the exporter reads (default
      `["public"]`) and `config.precision` selects the export mode.
    * `--engine postgres|cockroachdb` — steers `--emit-sql` dialect only;
      ignored by the live and `--from-file` paths, which detect the engine.
    * `--migration-source NAME` — applied-migrations table for `--url`
      (default `schema_migrations`).
    * `--precision exact|order_of_magnitude` — override `config.precision`.
      `order_of_magnitude` buckets every count and byte to its power-of-ten
      floor so business scale is not exported verbatim.

  ## Signing (tamper-proofing)

    * `--gen-signing-key PATH` — generate an Ed25519 keypair, write the seed
      to `PATH` (mode 0600), print the public key for `snapshot_verify_keys`,
      and exit. Ignores every other flag.
    * `--sign-key PATH` — sign the exported snapshot with the seed at `PATH`.
      A missing or malformed seed is an operational error (exit 2).

  ## Examples

      # Live export against a read-only replica
      mix cerbero.snapshot --url ecto://user:pass@replica/app_prod

      # DBA path: emit SQL, run it elsewhere, ingest the result
      mix cerbero.snapshot --emit-sql --engine cockroachdb > catalog.sql
      mix cerbero.snapshot --from-file catalog.out

      # Generate a signing key, then export signed
      mix cerbero.snapshot --gen-signing-key priv/cerbero_signing.key
      mix cerbero.snapshot --url $DATABASE_URL --sign-key priv/cerbero_signing.key

  ## Exit codes

    * `0` — snapshot written (or SQL/keypair emitted).
    * `2` — operational error (unreachable database, bad config, invalid
      `--precision`/`--engine`, unusable signing key).

  Implemented by `Cerbero.CLI.Snapshot`.
  """
  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    case Cerbero.CLI.Snapshot.run(argv) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end
end
