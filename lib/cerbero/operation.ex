defmodule Cerbero.Operation do
  @moduledoc "Typed operations mirroring Ecto migration DSL semantics, with source lines."

  defmodule CreateTable do
    @moduledoc "`create table(...)` with its column definitions."
    defstruct [:table, :line, columns: []]
  end

  defmodule AlterTable do
    @moduledoc "`alter table(...)` with its add/modify/remove column ops."
    defstruct [:table, :line, ops: []]
  end

  defmodule CreateIndex do
    @moduledoc "`create index(...)`, including unique/concurrently options."
    defstruct [:table, :line, keys: [], concurrently: false, unique: false]
  end

  defmodule DropIndex do
    @moduledoc "`drop index(...)`, including the concurrently option."
    defstruct [:table, :line, concurrently: false]
  end

  defmodule CreateConstraint do
    @moduledoc "`create constraint(...)`, including CHECK body and validate option."
    defstruct [:table, :name, :line, check: nil, validate: true]
  end

  defmodule DropTable do
    @moduledoc "`drop table(...)`."
    defstruct [:table, :line]
  end

  defmodule RenameOp do
    @moduledoc "`rename table(...), to: ...` (table or column rename)."
    defstruct [:table, :line]
  end

  defmodule RawSQL do
    @moduledoc "`execute \"...\"` with the classifier's reading of each statement."
    defstruct [:sql, :line, classified: []]
  end

  defmodule Unknown do
    @moduledoc "A dynamically-built operation the static parser cannot read — never silence."
    defstruct [:line, :description]
  end
end
