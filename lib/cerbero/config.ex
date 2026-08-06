defmodule Cerbero.Config do
  @moduledoc "Checker configuration, loaded from `.cerbero.exs` (a keyword list)."

  defstruct rows_warning: 100_000,
            rows_error: 1_000_000,
            bytes_error: 1_073_741_824,
            hot_ops_per_sec: 1.0,
            headroom_days: 14,
            headroom_multiplier: 0.5,
            stale_warn_days: 30,
            stale_degrade_days: 90,
            fail_on: :error,
            skip_checks: [],
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
      [] -> {:ok, struct!(__MODULE__, opts)}
      unknown -> {:error, {:bad_config, "unknown config keys: #{inspect(unknown)}"}}
    end
  end
end
