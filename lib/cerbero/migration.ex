defmodule Cerbero.Migration do
  @moduledoc "A parsed migration file: attributes + ordered operations."

  defstruct file: nil,
            module: nil,
            version: nil,
            attrs: %{
              disable_ddl_transaction: false,
              disable_migration_lock: false,
              cerbero_skip: []
            },
            operations: []

  @type t :: %__MODULE__{}
end
