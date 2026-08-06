defmodule Cerbero.CLI.Snapshot do
  @moduledoc "argv for mix cerbero.snapshot: --url | --emit-sql | --from-file, --out, --migration-source."

  alias Cerbero.Snapshot
  alias Cerbero.Snapshot.Exporter

  @switches [
    url: :string,
    out: :string,
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

    result =
      cond do
        parsed[:emit_sql] ->
          {:emit, Exporter.emit_sql()}

        parsed[:from_file] ->
          Exporter.from_file(parsed[:from_file], clock: clock)

        parsed[:url] ->
          Exporter.export(parsed[:url],
            clock: clock,
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
        IO.write(io, "cerbero: error: #{inspect(reason)}\n")
        2
    end
  end
end
