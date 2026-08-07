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
  """

  @callback id() :: atom()
  @callback run(Cerbero.Migration.t(), Cerbero.Catalog.t(), Cerbero.Config.t()) ::
              [Cerbero.Finding.t()]
end
