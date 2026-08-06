defmodule Cerbero.Check do
  @moduledoc """
  Behaviour for migration checks. Internal rules are its first consumers;
  it is public API by design (spec constraint, born from real Credo-check
  pain).
  """

  @callback id() :: atom()
  @callback run(Cerbero.Migration.t(), Cerbero.Catalog.t(), Cerbero.Config.t()) ::
              [Cerbero.Finding.t()]
end
