defmodule Cerbero.CLI.Snapshot do
  @moduledoc """
  argv for mix cerbero.snapshot: --url | --emit-sql | --from-file, --out,
  --config, --migration-source, --precision, --engine (postgres |
  cockroachdb; steers --emit-sql only — the live path detects the engine
  from the connection and --from-file from the file's own sections).

  Loads `.cerbero.exs` (or the path given via `--config`) the same way
  `mix cerbero.check` does, so `config.schemas` governs which schemas the
  exporter reads instead of the connection always being hardcoded to
  `["public"]`, and `config.precision` selects the export mode
  (`--precision exact|order_of_magnitude` overrides it). A bad config or an
  invalid precision is an operational error (exit 2), same category as an
  unreachable database.
  """

  alias Cerbero.{Config, Snapshot}
  alias Cerbero.Snapshot.Exporter

  @switches [
    url: :string,
    out: :string,
    config: :string,
    emit_sql: :boolean,
    engine: :string,
    from_file: :string,
    migration_source: :string,
    precision: :string
  ]

  @spec run([String.t()], keyword()) :: 0 | 2
  def run(argv, opts \\ []) do
    io = Keyword.get(opts, :io, :stdio)
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    {parsed, _, _} = OptionParser.parse(argv, strict: @switches)
    out = parsed[:out] || "priv/repo/cerbero_snapshot.json"

    with {:ok, config} <- Config.load(parsed[:config] || ".cerbero.exs"),
         {:ok, precision} <- precision(parsed, config),
         {:ok, engine} <- engine(parsed) do
      do_run(parsed, config, precision, engine, out, clock, io)
    else
      {:error, reason} -> error(io, reason)
    end
  end

  # --engine only steers --emit-sql (the live path detects the engine from
  # the connection; --from-file detects it from the file's own sections).
  defp engine(parsed) do
    case parsed[:engine] do
      nil -> {:ok, "postgres"}
      "postgres" -> {:ok, "postgres"}
      "cockroachdb" -> {:ok, "cockroachdb"}
      other -> {:error, "invalid --engine: #{other} (postgres | cockroachdb)"}
    end
  end

  defp precision(parsed, config) do
    case parsed[:precision] do
      nil -> {:ok, config.precision}
      "exact" -> {:ok, :exact}
      "order_of_magnitude" -> {:ok, :order_of_magnitude}
      other -> {:error, "invalid --precision: #{other} (exact | order_of_magnitude)"}
    end
  end

  defp do_run(parsed, config, precision, engine, out, clock, io) do
    result =
      cond do
        parsed[:emit_sql] ->
          {:emit, Exporter.emit_sql(engine)}

        parsed[:from_file] ->
          Exporter.from_file(parsed[:from_file], clock: clock, precision: precision)

        parsed[:url] ->
          Exporter.export(parsed[:url],
            clock: clock,
            schemas: config.schemas,
            precision: precision,
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
