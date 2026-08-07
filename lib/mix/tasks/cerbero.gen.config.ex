defmodule Mix.Tasks.Cerbero.Gen.Config do
  @shortdoc "Generate a .cerbero.exs populated with the built-in defaults"
  @moduledoc """
  See `Cerbero.CLI.GenConfig` for flags: `--out`, `--force`. Exit codes:
  0 success, 2 operational error.
  """
  use Mix.Task

  @impl true
  def run(argv) do
    case Cerbero.CLI.GenConfig.run(argv) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end
end
