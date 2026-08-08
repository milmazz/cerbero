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

  `--out` defaults to `config.snapshot_path`, so the exported snapshot lands
  exactly where `mix cerbero.check` reads it.
  """

  alias Cerbero.{Config, Snapshot}
  alias Cerbero.Snapshot.{Exporter, Signature}

  @switches [
    url: :string,
    out: :string,
    config: :string,
    emit_sql: :boolean,
    engine: :string,
    from_file: :string,
    gen_signing_key: :string,
    migration_source: :string,
    precision: :string,
    sign_key: :string
  ]

  @spec run([String.t()], keyword()) :: 0 | 2
  def run(argv, opts \\ []) do
    io = Keyword.get(opts, :io, :stdio)
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    {parsed, _, _} = OptionParser.parse(argv, strict: @switches)

    case parsed[:gen_signing_key] do
      nil ->
        with {:ok, config} <- Config.load(parsed[:config] || ".cerbero.exs"),
             {:ok, precision} <- precision(parsed, config),
             {:ok, engine} <- engine(parsed),
             {:ok, sign_seed} <- sign_seed(parsed) do
          # --out wins; otherwise write where mix cerbero.check reads
          # (config.snapshot_path), so the two tasks always agree.
          out = parsed[:out] || config.snapshot_path
          do_run(parsed, config, precision, engine, sign_seed, out, clock, io)
        else
          {:error, reason} -> error(io, reason)
        end

      key_path ->
        gen_signing_key(key_path, io)
    end
  end

  # Keypair generation for snapshot signing: seed (base64) to the file,
  # public key to stdout for .cerbero.exs snapshot_verify_keys.
  defp gen_signing_key(path, io) do
    {pub, seed} = Signature.generate()
    File.write!(path, seed <> "\n")
    File.chmod(path, 0o600)
    IO.write(io, "cerbero: wrote #{path}\npublic key: #{pub}\n")
    0
  end

  # Read and validate the seed before touching any database, so a bad key
  # file is a fast exit 2, not a wasted export.
  defp sign_seed(parsed) do
    case parsed[:sign_key] do
      nil ->
        {:ok, nil}

      path ->
        with {:ok, contents} <- File.read(path),
             {:ok, seed} <- Base.decode64(String.trim(contents)),
             32 <- byte_size(seed) do
          {:ok, String.trim(contents)}
        else
          _ ->
            {:error,
             "cannot use --sign-key #{path}: must be a readable base64 32-byte ed25519 seed " <>
               "(generate one with --gen-signing-key)"}
        end
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

  defp do_run(parsed, config, precision, engine, sign_seed, out, clock, io) do
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
        raw = maybe_sign(raw, sign_seed)
        Snapshot.write!(raw, out)
        IO.write(io, "cerbero: wrote #{out}\n")
        0

      {:error, reason} ->
        error(io, reason)
    end
  end

  defp maybe_sign(raw, nil), do: raw

  defp maybe_sign(raw, seed),
    do: raw |> Snapshot.stamp() |> Signature.sign(seed)

  defp error(io, reason) do
    IO.write(io, "cerbero: error: #{inspect(reason)}\n")
    2
  end
end
