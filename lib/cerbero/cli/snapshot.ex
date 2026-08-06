defmodule Cerbero.CLI.Snapshot do
  @moduledoc """
  argv for mix cerbero.snapshot: --url | --emit-sql | --from-file, --out,
  --config, --migration-source.

  Loads `.cerbero.exs` (or the path given via `--config`) the same way
  `mix cerbero.check` does, so `config.schemas` governs which schemas the
  exporter reads instead of the connection always being hardcoded to
  `["public"]`. A bad config is an operational error (exit 2), same
  category as an unreachable database.
  """

  alias Cerbero.{Config, Snapshot}
  alias Cerbero.Snapshot.Exporter

  @switches [
    url: :string,
    out: :string,
    config: :string,
    emit_sql: :boolean,
    from_file: :string,
    migration_source: :string
  ]

  @spec run([String.t()], keyword()) :: 0 | 2
  def run(argv, opts \\ []) do
    io = Keyword.get(opts, :io, :stdio)
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    {parsed, _, _} = OptionParser.parse(argv, strict: @switches)
    out = parsed[:out] || "priv/repo/cerbero_snapshot.json"

    case Config.load(parsed[:config] || ".cerbero.exs") do
      {:ok, config} -> do_run(parsed, config, out, clock, io)
      {:error, reason} -> error(io, reason)
    end
  end

  defp do_run(parsed, config, out, clock, io) do
    result =
      cond do
        parsed[:emit_sql] ->
          {:emit, Exporter.emit_sql()}

        parsed[:from_file] ->
          Exporter.from_file(parsed[:from_file], clock: clock)

        parsed[:url] ->
          Exporter.export(parsed[:url],
            clock: clock,
            schemas: config.schemas,
            migration_source: parsed[:migration_source] || "schema_migrations"
          )

        true ->
          {:error, "one of --url, --emit-sql, --from-file is required"}
      end

    case result do
      {:emit, script} ->
        IO.write(io, script)
        0

      {:ok, raw} ->
        Snapshot.write!(raw, out)
        IO.write(io, "cerbero: wrote #{out}\n")
        0

      {:error, reason} ->
        error(io, reason)
    end
  end

  defp error(io, reason) do
    IO.write(io, "cerbero: error: #{inspect(reason)}\n")
    2
  end
end
