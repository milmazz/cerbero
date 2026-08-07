defmodule Mix.Tasks.Cerbero.Snapshot do
  @shortdoc "Export a cerbero catalog snapshot from a database"
  @moduledoc """
  See `Cerbero.CLI.Snapshot` for flags: `--url`, `--out`, `--emit-sql`,
  `--engine`, `--from-file`, `--migration-source`. Exit codes: 0 success,
  2 operational error.
  """
  use Mix.Task

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    case Cerbero.CLI.Snapshot.run(argv) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end
end
