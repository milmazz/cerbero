defmodule Cerbero.DDL.Effect do
  @moduledoc "What one operation does to the database: lock mode, cost class, touched relations."

  defstruct [:class, :lock, :cost, relations: [], unmapped: false, line: nil]

  @type lock ::
          :access_exclusive
          | :share
          | :share_row_exclusive
          | :share_update_exclusive
          | :row_exclusive
          | :none
          | :online_schema_change
  @type cost :: :metadata_only | :full_scan | :rewrite
  @type t :: %__MODULE__{}
end
