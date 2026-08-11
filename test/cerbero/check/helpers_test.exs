defmodule Cerbero.Check.HelpersTest do
  use ExUnit.Case, async: true

  alias Cerbero.Check.Helpers
  alias Cerbero.Finding
  alias Cerbero.Migration

  defmodule FakeCheck do
    @moduledoc false
    def id, do: :fake_check
  end

  describe "finding/6 source parameter" do
    test "a %Migration{} source reads only its file (existing contract)" do
      migration = %Migration{file: "priv/repo/migrations/1_a.exs"}

      assert %Finding{
               check: :fake_check,
               severity: :warning,
               message: "m",
               file: "priv/repo/migrations/1_a.exs",
               line: 4,
               relations: ["public.events"],
               engine: :postgres,
               metadata: %{lock: :share}
             } =
               Helpers.finding(FakeCheck, :warning, "m", migration, 4,
                 relations: ["public.events"],
                 engine: :postgres,
                 metadata: %{lock: :share}
               )
    end

    test "a binary source is the file path itself" do
      assert %Finding{file: "1_a.exs", line: 2} =
               Helpers.finding(FakeCheck, :error, "m", "1_a.exs", 2)
    end

    test "a nil source is a global finding (no file, no line)" do
      assert %Finding{file: nil, line: nil, relations: [], engine: nil, metadata: %{}} =
               Helpers.finding(FakeCheck, :warning, "m", nil, nil)
    end
  end
end
