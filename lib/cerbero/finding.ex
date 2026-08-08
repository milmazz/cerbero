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

  @doc """
  The stable ordering contract for machine output: file, then line, then
  check name, with global findings (nil file/line) first. Both the JSON
  and SARIF formatters depend on this exact ordering — their outputs are
  golden-tested byte-for-byte, so the key lives here, once.
  """
  @spec stable_sort([t()]) :: [t()]
  def stable_sort(findings), do: Enum.sort_by(findings, &{&1.file || "", &1.line || 0, Atom.to_string(&1.check)})
end
