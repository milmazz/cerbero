defmodule Mix.Tasks.Cerbero.Check do
  @shortdoc "Judge pending migrations against the committed cerbero snapshot"
  @moduledoc "See Cerbero.CLI.Check for flags. Exit codes: 0 clean, 1 findings, 2 operational error."
  use Mix.Task

  @impl true
  def run(argv) do
    case Cerbero.CLI.Check.run(argv) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end
end
