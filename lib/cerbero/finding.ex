defmodule Cerbero.Finding do
  @moduledoc """
  One judged fact: mechanism + scale + provenance, with source location.

  ## The `metadata` contract

  `metadata` records as data what the message says in prose. It is
  serialized verbatim into `--format json` output through the canonical
  encoder, so every value must be JSON-encodable: maps (atom or string
  keys), lists, strings, atoms (encoded as strings), numbers, booleans —
  never tuples, PIDs, refs, functions, or structs. A non-encodable value
  raises at render time instead of the CLI's usual exit-2 error path, so
  third-party checks (`extra_checks`) must respect this.

  Reserved keys, written by the runner/CLI machinery — set them only with
  their documented meaning:

    * `:lock` — the lock mode a rule judged (`Cerbero.DDL.Effect` lock
      atom); the lock-timeout attestation keys on it.
    * `:skipped` — `%{via: [:migration_attribute | :config, ...]}` in
      application order, plus `:reason` for `@cerbero_skip`; written by
      the runner when a finding is demoted.
    * `:direction` — `:down` on `--down` findings.
    * `:no_snapshot` — `true` in structural (no-snapshot) mode.
  """

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
