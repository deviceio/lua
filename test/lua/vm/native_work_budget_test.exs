defmodule Lua.VM.NativeWorkBudgetTest do
  @moduledoc "Pins the instruction budget's charge for work done inside stdlib calls."
  use ExUnit.Case, async: true

  import Lua.Test.Bounded, only: [eval: 3]

  @single_call_bombs [
    ~S|return select("#", string.byte(string.rep("x", 1000000), 1, -1))|,
    ~S|local t = {string.byte(string.rep("x", 1000000), 1, -1)} return #t|,
    ~S|return select("#", utf8.codepoint(string.rep("x", 1000000), 1, -1))|,
    ~S|local s = string.rep("a", 1000000) local p = string.rep("a", 500000) .. "b" for i = 1, 200 do string.find(s, p, 1, true) end|,
    ~S|return #string.format("%q", string.rep("\n", 900000))|,
    ~S|return #os.date(string.rep("%Y", 300000))|,
    ~S|return #string.pack(string.rep("x", 1000000))|,
    ~S|local t = {string.byte(string.rep("1", 400000), 1, -1)} return #table.concat(t)|,
    ~S|local t = {string.byte(string.rep("x", 1000000), 1, -1)} table.sort(t) return #t|,
    ~S|local s = string.rep("a", 1000000) return #string.upper(s), #string.lower(s), #string.reverse(s)|
  ]

  defp budgeted, do: Lua.new(max_instructions: 10_000, max_call_depth: 100, max_string_bytes: 1024 * 1024)

  defp budget_error?({:raised, message}), do: message =~ "instruction budget exceeded"
  defp budget_error?({:ok, [false, message]}), do: message =~ "instruction budget exceeded"
  defp budget_error?(_result), do: false

  defp assert_charged(lua, call) do
    result = eval(lua, "return pcall(function() return #{call} end)", timeout_ms: 1_000)
    assert {:ok, [false, message]} = result, "#{call}\n  => #{inspect(result, limit: 5)}"
    assert message =~ "instruction budget exceeded", call
  end

  test "single-call bombs fail fast under a small budget" do
    for code <- @single_call_bombs do
      result = eval(budgeted(), code, timeout_ms: 1_000)
      assert budget_error?(result), "#{code}\n  => #{inspect(result, limit: 5)}"
    end
  end

  describe "a call is charged for its input, before the work" do
    setup do
      lua =
        budgeted()
        |> Lua.set!([:s], String.duplicate("x", 1_000_000))
        |> Lua.set!([:dates], String.duplicate("%Y", 200_000))
        |> Lua.set!([:padding], String.duplicate("x", 1_000_000))
        |> Lua.set!([:digits], String.duplicate("9", 300_000))
        |> Lua.set!([:t], Enum.to_list(1..200_000))

      %{lua: lua}
    end

    test "string and utf8 calls, per byte scanned or built", %{lua: lua} do
      for call <- [
            ~S|string.byte(s, 1, -1)|,
            ~S|utf8.codepoint(s, 1, -1)|,
            ~S|utf8.len(s)|,
            ~S|utf8.offset(s, 1000000)|,
            ~S|string.upper(s)|,
            ~S|string.lower(s)|,
            ~S|string.reverse(s)|,
            ~S|string.find(s, "y", 1, true)|,
            ~S|string.format("%q", s)|,
            ~S|string.format("%s", s)|,
            ~S|string.rep("ab", 500000)|,
            ~S|os.date(dates)|,
            ~S|string.pack(padding)|,
            ~S|string.packsize(padding)|,
            ~S|string.unpack(padding, s)|,
            ~S|string.gsub("x", "x", s)|
          ] do
        assert_charged(lua, call)
      end
    end

    test "string to number conversions, per byte scanned", %{lua: lua} do
      for call <- [
            ~S|tonumber(digits)|,
            ~S|tonumber(s, 36)|,
            ~S|math.tointeger(digits)|
          ] do
        assert_charged(lua, call)
      end
    end

    test "table calls, per element visited or returned", %{lua: lua} do
      for call <- [
            ~S|table.unpack(t)|,
            ~S|table.concat(t, ",")|,
            ~S|table.sort(t)|,
            ~S|table.insert(t, 1, 0)|,
            ~S|table.remove(t, 1)|,
            ~S|table.move(t, 1, #t, 2)|
          ] do
        assert_charged(lua, call)
      end
    end
  end

  test "charges accumulate across calls" do
    lua = Lua.set!(budgeted(), [:s], String.duplicate("a", 100_000))

    assert {:ok, [100_000]} = eval(lua, "return #string.upper(s)", timeout_ms: 1_000)
    assert budget_error?(eval(lua, "return pcall(function() string.upper(s) string.upper(s) end)", timeout_ms: 1_000))
  end

  test "utf8.offset is charged for the bytes it crosses, not the whole string" do
    lua = Lua.set!(budgeted(), [:s], String.duplicate("x", 200_000))

    assert {:ok, [nil, nil]} = eval(lua, "return utf8.offset(s, -1, 1), utf8.offset(s, 3, -1)", timeout_ms: 1_000)
  end

  test "table.sort calls a comparator no more often than it charges for" do
    code = ~S"""
    local t, calls = {}, 0
    for i = 1, 1000 do t[i] = i end
    table.sort(t, function(a, b) calls = calls + 1 return false end)
    return calls
    """

    assert {:ok, [calls]} = eval(Lua.new(), code, timeout_ms: 1_000)
    assert calls <= 1000 * ceil(:math.log2(1000))
  end

  test "ordinary calls still run under a small budget" do
    code = ~S"""
    local words = {}
    for w in string.gmatch("the quick brown fox jumps over the lazy dog", "%a+") do
      words[#words + 1] = string.upper(w)
    end
    table.sort(words)
    local n, z = string.unpack("<i4 z", string.pack("<i4 z", 42, "hi"))
    return table.concat(words, ",", 1, 3),
           string.format("%q|%5.2f", "a\nb", 3.14159),
           select("#", string.byte(string.rep("ab", 5000), 1, -1)),
           utf8.len("héllo"), n, z, tonumber("ff", 16), tonumber("  12  ") + 1,
           #string.rep("ab", 3000, "-"), os.date("!%Y", 0)
    """

    assert {:ok, ["BROWN,DOG,FOX", ~s|"a\\\nb"| <> "| 3.14", 10_000, 5, 42, "hi", 255, 13, 8999, "1970"]} =
             eval(budgeted(), code, timeout_ms: 1_000)
  end
end
