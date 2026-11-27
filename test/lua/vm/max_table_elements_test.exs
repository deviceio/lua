defmodule Lua.VM.MaxTableElementsTest do
  @moduledoc "Pins the `:max_table_elements` ceiling."
  use ExUnit.Case, async: true

  import Lua.Test.Bounded, only: [eval: 2, eval: 3]

  defp small_ceiling_lua, do: Lua.new(max_table_elements: 100)

  describe "default ceiling" do
    test "refuses the table.unpack bomb before allocating" do
      code = ~S|return pcall(function() return select('#', table.unpack({}, 1, 9999999)) end)|
      assert {:ok, [false, message]} = eval(Lua.new(), code, timeout_ms: 5_000, heap_bytes: 64 * 1024 * 1024)
      assert message =~ "too many results to unpack"
    end

    test "is one million" do
      assert {:ok, [1_000_000]} = eval(Lua.new(), ~S|return select('#', table.unpack({}, 1, 1000000))|)
      assert {:ok, [false, message]} = eval(Lua.new(), ~S|return pcall(table.unpack, {}, 1, 1000001)|)
      assert message =~ "too many results to unpack"
    end
  end

  describe "a lowered ceiling" do
    test "bounds table.unpack" do
      assert {:ok, [100]} = eval(small_ceiling_lua(), ~S|return select('#', table.unpack({}, 1, 100))|)
      assert {:ok, [false, message]} = eval(small_ceiling_lua(), ~S|return pcall(table.unpack, {}, 1, 101)|)
      assert message =~ "too many results to unpack"
    end

    test "bounds table.concat, table.move and table.sort" do
      assert {:ok, [false, concat]} = eval(small_ceiling_lua(), ~S|return pcall(table.concat, {}, ",", 1, 101)|)
      assert concat =~ "range too large"

      assert {:ok, [false, move]} = eval(small_ceiling_lua(), ~S|return pcall(table.move, {}, 1, 101, 1)|)
      assert move =~ "range too large"

      sort = ~S|local t = {} for i = 1, 101 do t[i] = i end return pcall(table.sort, t)|
      assert {:ok, [false, sort_message]} = eval(small_ceiling_lua(), sort)
      assert sort_message =~ "array too big"

      in_bounds = ~S"""
      local t = {}
      for i = 1, 100 do t[i] = 101 - i end
      table.sort(t)
      local moved = table.move(t, 1, 100, 1, {})
      return t[1], t[100], #table.concat(moved, ","), moved[100]
      """

      assert {:ok, [1, 100, 291, 100]} = eval(small_ceiling_lua(), in_bounds)
    end

    test "bounds string.byte and utf8.codepoint" do
      byte = ~S|return pcall(string.byte, string.rep("a", 101), 1, -1)|
      assert {:ok, [false, byte_message]} = eval(small_ceiling_lua(), byte)
      assert byte_message =~ "string slice too long"

      codepoint = ~S|return pcall(utf8.codepoint, string.rep("a", 101), 1, -1)|
      assert {:ok, [false, codepoint_message]} = eval(small_ceiling_lua(), codepoint)
      assert codepoint_message =~ "string slice too long"

      in_bounds =
        ~S|local s = string.rep("a", 100) return select('#', string.byte(s, 1, -1)), select('#', utf8.codepoint(s, 1, -1))|

      assert {:ok, [100, 100]} = eval(small_ceiling_lua(), in_bounds)
    end

    test "counts utf8.codepoint results, not the bytes they span" do
      in_bounds = ~S|return select('#', utf8.codepoint(string.rep("é", 100), 1, -1))|
      assert {:ok, [100]} = eval(small_ceiling_lua(), in_bounds)

      over = ~S|return pcall(utf8.codepoint, string.rep("é", 101), 1, -1)|
      assert {:ok, [false, message]} = eval(small_ceiling_lua(), over)
      assert message =~ "string slice too long"
    end

    test "bounds string.unpack, counting the trailing position" do
      over = ~S|return pcall(string.unpack, string.rep("b", 100), string.rep("x", 100))|
      assert {:ok, [false, message]} = eval(small_ceiling_lua(), over)
      assert message =~ "too many results"

      in_bounds = ~S|return select('#', string.unpack(string.rep("b", 99), string.rep("x", 99)))|
      assert {:ok, [100]} = eval(small_ceiling_lua(), in_bounds)
    end
  end

  describe "table.insert and table.remove" do
    @lying_len ~S|setmetatable({}, {__len = function() return math.maxinteger end})|

    test "refuse a shift past the ceiling" do
      assert {:ok, [false, insert]} = eval(Lua.new(), "return pcall(table.insert, #{@lying_len}, 1, 'x')")
      assert insert =~ "range too large"

      assert {:ok, [false, remove]} = eval(Lua.new(), "return pcall(table.remove, #{@lying_len}, 1)")
      assert remove =~ "range too large"
    end

    test "still shift ordinary lists" do
      code = ~S"""
      local t = {1, 2, 3}
      table.insert(t, 1, 0)
      table.insert(t, 9)
      local removed = table.remove(t, 2)
      return removed, table.concat(t, ",")
      """

      assert {:ok, [1, "0,2,3,9"]} = eval(small_ceiling_lua(), code)
    end
  end

  test ":infinity lifts the ceiling" do
    unbounded = Lua.new(max_table_elements: :infinity)
    assert {:ok, [1_000_001]} = eval(unbounded, ~S|return select('#', table.unpack({}, 1, 1000001))|)

    assert {:ok, [1_000_001]} =
             eval(unbounded, ~S|local s = string.rep("a", 1000001) return select('#', string.byte(s, 1, -1))|)
  end

  describe "option validation" do
    test "rejects non-positive and non-integer values" do
      for bad <- [0, -1, 1.5, "1m", nil] do
        assert_raise ArgumentError, ~r/:max_table_elements must be a positive integer or :infinity/, fn ->
          Lua.new(max_table_elements: bad)
        end
      end
    end

    test "accepts a positive integer or :infinity" do
      assert %Lua{} = Lua.new(max_table_elements: 1)
      assert %Lua{} = Lua.new(max_table_elements: :infinity)
    end
  end
end
