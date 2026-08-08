defmodule Cerbero.FindingTest do
  use ExUnit.Case, async: true

  alias Cerbero.Finding

  defp finding(overrides) do
    struct!(
      %Finding{check: :unsafe_index_creation, severity: :error, message: "m"},
      overrides
    )
  end

  describe "stable_sort/1" do
    test "orders by file, then line, then check name" do
      b1 = finding(file: "b.exs", line: 1, check: :not_null)
      a9 = finding(file: "a.exs", line: 9, check: :not_null)
      a2_z = finding(file: "a.exs", line: 2, check: :unsafe_index_creation)
      a2_a = finding(file: "a.exs", line: 2, check: :column_type_change)

      assert Finding.stable_sort([b1, a9, a2_z, a2_a]) == [a2_a, a2_z, a9, b1]
    end

    test "nil file and nil line sort first (global findings lead)" do
      global = finding(file: nil, line: nil, check: :snapshot_health)
      no_line = finding(file: "a.exs", line: nil, check: :not_null)
      located = finding(file: "a.exs", line: 3, check: :not_null)

      assert Finding.stable_sort([located, no_line, global]) == [global, no_line, located]
    end
  end
end
