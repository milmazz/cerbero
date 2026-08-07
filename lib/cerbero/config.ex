defmodule Cerbero.Config do
  @moduledoc "Checker configuration, loaded from `.cerbero.exs` (a keyword list)."

  defstruct rows_warning: 100_000,
            rows_error: 1_000_000,
            bytes_error: 1_073_741_824,
            hot_ops_per_sec: 1.0,
            deploy_cadence: 1,
            headroom_days: 14,
            headroom_multiplier: 0.5,
            stale_warn_days: 30,
            stale_degrade_days: 90,
            fail_on: :error,
            skip_checks: [],
            extra_checks: [],
            severity_overrides: %{},
            lock_timeout_attested: false,
            strict_concurrent_index: false,
            start_after: nil,
            precision: :exact,
            schemas: ["public"],
            migrations_paths: ["priv/repo/migrations"],
            snapshot_path: "priv/repo/cerbero_snapshot.json",
            repos: []

  @type t :: %__MODULE__{}

  @spec load(Path.t()) :: {:ok, t()} | {:error, {:bad_config, String.t()}}
  def load(path \\ ".cerbero.exs") do
    if File.exists?(path) do
      {opts, _bindings} = Code.eval_file(path)
      from_keyword(opts)
    else
      {:ok, %__MODULE__{}}
    end
  rescue
    e -> {:error, {:bad_config, Exception.message(e)}}
  end

  @spec from_keyword(keyword()) :: {:ok, t()} | {:error, {:bad_config, String.t()}}
  def from_keyword(opts) do
    known = Map.keys(%__MODULE__{}) -- [:__struct__]

    case Keyword.keys(opts) -- known do
      [] ->
        with {:ok, config} <- validate_extra_checks(struct!(__MODULE__, opts)) do
          validate_repos(config)
        end

      unknown ->
        {:error, {:bad_config, "unknown config keys: #{inspect(unknown)}"}}
    end
  end

  # Multi-repo (umbrella) support: each entry names one Ecto repo's
  # migrations and snapshot. Normalized to maps at load so downstream code
  # never re-checks shapes; every other setting stays global.
  defp validate_repos(%__MODULE__{repos: repos} = config) when is_list(repos) do
    normalized = Enum.map(repos, &normalize_repo/1)

    cond do
      Enum.any?(normalized, &match?({:error, _}, &1)) ->
        {:error, bad} = Enum.find(normalized, &match?({:error, _}, &1))
        {:error, {:bad_config, "repos: #{bad}"}}

      normalized |> Enum.map(& &1.name) |> Enum.uniq() |> length() != length(normalized) ->
        {:error, {:bad_config, "repos: duplicate repo names"}}

      true ->
        {:ok, %{config | repos: normalized}}
    end
  end

  defp validate_repos(%__MODULE__{repos: other}) do
    {:error, {:bad_config, "repos must be a list of entries, got: #{inspect(other)}"}}
  end

  defp normalize_repo(entry) when is_list(entry) or is_map(entry) do
    entry = Map.new(entry)
    name = entry[:name]
    migrations_paths = entry[:migrations_paths]
    snapshot_path = entry[:snapshot_path]

    if is_binary(name) and is_list(migrations_paths) and migrations_paths != [] and
         Enum.all?(migrations_paths, &is_binary/1) and is_binary(snapshot_path) and
         map_size(entry) == 3 do
      %{name: name, migrations_paths: migrations_paths, snapshot_path: snapshot_path}
    else
      {:error,
       "each entry needs exactly name (string), migrations_paths (non-empty list of " <>
         "strings), snapshot_path (string); got: #{inspect(entry)}"}
    end
  end

  defp normalize_repo(other) do
    {:error, "each entry must be a keyword list or map, got: #{inspect(other)}"}
  end

  # Registration is validated at load time so a typo'd or non-conforming
  # module is exit 2 with a named culprit, not a crash mid-run.
  defp validate_extra_checks(%__MODULE__{extra_checks: checks} = config) when is_list(checks) do
    case Enum.reject(checks, &implements_check?/1) do
      [] ->
        {:ok, config}

      bad ->
        {:error,
         {:bad_config,
          "extra_checks entries must be modules implementing the Cerbero.Check " <>
            "behaviour (id/0 and run/3): #{inspect(bad)}"}}
    end
  end

  defp validate_extra_checks(%__MODULE__{extra_checks: other}) do
    {:error, {:bad_config, "extra_checks must be a list of modules, got: #{inspect(other)}"}}
  end

  defp implements_check?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :id, 0) and
      function_exported?(module, :run, 3)
  end

  defp implements_check?(_other), do: false
end
