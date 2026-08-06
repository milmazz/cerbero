defmodule Cerbero.Operation do
  @moduledoc "Typed operations mirroring Ecto migration DSL semantics, with source lines."

  defmodule CreateTable do
    defstruct [:table, :line, columns: []]
  end

  defmodule AlterTable do
    defstruct [:table, :line, ops: []]
  end

  defmodule CreateIndex do
    defstruct [:table, :line, keys: [], concurrently: false, unique: false]
  end

  defmodule DropIndex do
    defstruct [:table, :line, concurrently: false]
  end

  defmodule CreateConstraint do
    defstruct [:table, :name, :line, check: nil, validate: true]
  end

  defmodule DropTable do
    defstruct [:table, :line]
  end

  defmodule RenameOp do
    defstruct [:table, :line]
  end

  defmodule RawSQL do
    defstruct [:sql, :line, classified: []]
  end

  defmodule Unknown do
    defstruct [:line, :description]
  end
end
