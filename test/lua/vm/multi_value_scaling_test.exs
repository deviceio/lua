defmodule Lua.VM.MultiValueScalingTest do
  @moduledoc "Pins linear-time placement of multi-results and varargs into registers."
  use ExUnit.Case, async: true

  import Lua.Test.Bounded, only: [eval: 3]

  defp eval(code), do: eval(Lua.new(), code, timeout_ms: 5_000)

  test "at the top level of a chunk" do
    code = ~S"""
    local s = string.rep("a", 200000)
    local t = {string.byte(s, 1, -1)}
    return #t, select('#', table.unpack(t)), select('#', string.byte(s, 1, -1))
    """

    assert {:ok, [200_000, 200_000, 200_000]} = eval(code)
  end

  test "through varargs and forwarded calls" do
    code = ~S"""
    local function count(...) return select('#', ...) end
    local function forward(...) return count(...) end
    local function pack(...) local t = {...} return #t end
    local function run(n)
      local s = string.rep("a", n)
      return forward(string.byte(s, 1, -1)), pack(string.byte(s, 1, -1)), select('#', table.unpack({}, 1, n))
    end
    return run(200000)
    """

    assert {:ok, [200_000, 200_000, 200_000]} = eval(code)
  end
end
