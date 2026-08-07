defmodule Mix.Tasks.Cerbero.Gen.Config do
  @shortdoc "Generate a .cerbero.exs populated with the built-in defaults"
  @moduledoc """
  Write a `.cerbero.exs` config file with every setting spelled out at its
  built-in default and commented, so the full surface is visible in one
  place. Deleting any line falls back to the same default — the file is a
  starting point to edit, not a required manifest. See `Cerbero.Config` for
  the meaning of each key.

  ## Options

    * `--out PATH` — where to write the config (default `.cerbero.exs`).
    * `--force` — overwrite an existing file. Without it, an existing file
      is never clobbered (exit 2).

  ## Examples

      # Scaffold .cerbero.exs in the project root
      mix cerbero.gen.config

      # Regenerate, overwriting the current file
      mix cerbero.gen.config --force

  ## Exit codes

    * `0` — config written.
    * `2` — operational error (target exists without `--force`, invalid flag).

  Implemented by `Cerbero.CLI.GenConfig`.
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
