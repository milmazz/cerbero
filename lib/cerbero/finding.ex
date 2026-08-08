defmodule Cerbero.Finding do
  @moduledoc "One judged fact: mechanism + scale + provenance, with source location."

  @enforce_keys [:check, :severity, :message]
  defstruct [:check, :severity, :message, :file, :line, relations: [], engine: nil, metadata: %{}]

  @type severity :: :error | :warning | :info
  @type t :: %__MODULE__{}

  @order %{error: 3, warning: 2, info: 1, none: 0}

  @spec at_least?(severity(), severity()) :: boolean()
  def at_least?(severity, threshold), do: @order[severity] >= @order[threshold]

  @spec most_severe([severity() | :none]) :: severity() | :none
  def most_severe(severities), do: Enum.max_by(severities, &Map.fetch!(@order, &1))
end
