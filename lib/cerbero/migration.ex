defmodule Cerbero.Migration do
  @moduledoc """
  A parsed migration file: attributes + ordered operations. `operations`
  holds the deploy direction (`up`/`change`); `down_operations` holds the
  rollback direction (`down` bodies, plus the down leg of two-arg
  `execute`), judged only when `mix cerbero.check --down` asks.
  """

  defstruct file: nil,
            module: nil,
            version: nil,
            attrs: %{
              disable_ddl_transaction: false,
              disable_migration_lock: false,
              cerbero_skip: []
            },
            operations: [],
            down_operations: []

  @type t :: %__MODULE__{}
end
