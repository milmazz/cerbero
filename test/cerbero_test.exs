defmodule CerberoTest do
  use ExUnit.Case
  doctest Cerbero

  test "greets the world" do
    assert Cerbero.hello() == :world
  end
end
