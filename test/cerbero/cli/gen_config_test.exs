defmodule Cerbero.CLI.GenConfigTest do
  use ExUnit.Case, async: true

  alias Cerbero.CLI.GenConfig
  alias Cerbero.Config

  defp run(argv) do
    {:ok, io} = StringIO.open("")
    code = GenConfig.run(argv, io: io)
    {_, output} = StringIO.contents(io)
    {code, output}
  end

  @tag :tmp_dir
  test "writes a config file that evaluates back to the built-in defaults", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".cerbero.exs")

    {code, output} = run(["--out", path])

    assert code == 0
    assert output =~ "wrote #{path}"
    assert File.exists?(path)
    assert {:ok, config} = Config.load(path)
    assert config == %Config{}
  end

  @tag :tmp_dir
  test "every config key appears in the generated file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".cerbero.exs")

    {0, _output} = run(["--out", path])
    content = File.read!(path)

    for key <- Map.keys(%Config{}) -- [:__struct__] do
      assert content =~ Atom.to_string(key)
    end
  end

  @tag :tmp_dir
  test "refuses to overwrite an existing file without --force", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".cerbero.exs")
    File.write!(path, "[fail_on: :warning]")

    {code, output} = run(["--out", path])

    assert code == 2
    assert output =~ "already exists"
    assert output =~ "--force"
    assert File.read!(path) == "[fail_on: :warning]"
  end

  @tag :tmp_dir
  test "--force overwrites an existing file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, ".cerbero.exs")
    File.write!(path, "[fail_on: :warning]")

    {code, _output} = run(["--out", path, "--force"])

    assert code == 0
    assert {:ok, config} = Config.load(path)
    assert config == %Config{}
  end

  test "an invalid option is exit 2" do
    {code, output} = run(["--nope"])

    assert code == 2
    assert output =~ "invalid options"
  end
end
