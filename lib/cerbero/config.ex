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
            snapshot_path: "priv/repo/cerbero_snapshot.json"

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
      [] -> validate_extra_checks(struct!(__MODULE__, opts))
      unknown -> {:error, {:bad_config, "unknown config keys: #{inspect(unknown)}"}}
    end
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
