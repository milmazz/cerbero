defmodule Cerbero.Check do
  @moduledoc """
  Behaviour for migration checks. Internal rules are its first consumers;
  it is public API by design (spec constraint, born from real Credo-check
  pain).

  Third-party checks register through the `extra_checks:` key in
  `.cerbero.exs` — a list of modules implementing this behaviour, validated
  at config load and run by `Cerbero.Check.Runner` after the built-in
  checks. Registered checks get the runner's machinery for free:
  `skip_checks`, `severity_overrides`, `@cerbero_skip`, and the
  lock-timeout attestation all key on the check's `id/0`.

  `description/0` is an optional extension point: a one-line, human-readable
  summary of what the check judges. The CLI collects descriptions from the
  configured check modules and feeds them to formatters that carry a rule
  catalog (SARIF `shortDescription`). A check without `description/0` still
  works everywhere — its id stands in for the description.
  """

  @callback id() :: atom()
  @callback run(Cerbero.Migration.t(), Cerbero.Catalog.t(), Cerbero.Config.t()) ::
              [Cerbero.Finding.t()]
  @callback description() :: String.t()

  @optional_callbacks [description: 0]
end
