defmodule Lua.VM.Stdlib.PatternBudgetTest do
  @moduledoc "Pins pattern-matching limits: instruction budget, captures, depth."
  use ExUnit.Case, async: true

  import Lua.Test.Bounded, only: [eval: 3]

  @lazy_bomb ~S|string.rep("a", 5000), ".-.-.-.-.-.-.-.-b"|
  @greedy_bomb ~S|string.rep("a", 60), "a*a*a*a*a*a*a*a*a*a*a*a*a*a*b"|

  defp budgeted, do: Lua.new(max_instructions: 10_000, max_string_bytes: 1024 * 1024)

  defp eval(lua, code), do: eval(lua, code, timeout_ms: 5_000)

  describe "instruction budget" do
    test "string.find bombs raise a catchable budget error" do
      for bomb <- [@lazy_bomb, @greedy_bomb] do
        assert {:ok, [false, message]} = eval(budgeted(), "return pcall(string.find, #{bomb})")
        assert message =~ "instruction budget exceeded"
      end
    end

    test "string.match, string.gsub and string.gmatch are metered" do
      for code <- [
            "return pcall(string.match, #{@greedy_bomb})",
            ~s|return pcall(string.gsub, #{@greedy_bomb}, "x")|,
            "return pcall(function() for _ in string.gmatch(#{@greedy_bomb}) do end end)"
          ] do
        assert {:ok, [false, message]} = eval(budgeted(), code)
        assert message =~ "instruction budget exceeded"
      end
    end

    test "aborts an unprotected evaluation" do
      assert {:raised, message} = eval(budgeted(), "return string.find(#{@lazy_bomb})")
      assert message =~ "instruction budget exceeded"
    end

    test "gsub charges every match" do
      code = ~S|return pcall(string.gsub, string.rep("ab", 50000), "%w", "x")|
      assert {:ok, [false, message]} = eval(budgeted(), code)
      assert message =~ "instruction budget exceeded"
    end

    test "gmatch charges each iteration as it runs" do
      full = ~S|return pcall(function() for _ in string.gmatch(string.rep("a", 100000), "a") do end end)|
      assert {:ok, [false, message]} = eval(budgeted(), full)
      assert message =~ "instruction budget exceeded"

      early = ~S|for w in string.gmatch(string.rep("a", 100000), "a") do return w end|
      assert {:ok, ["a"]} = eval(budgeted(), early)
    end

    test "charges accumulate across calls" do
      code = ~S"""
      local n = 0
      for i = 1, 5000 do
        if string.find("hello world, hello lua", "l+u") then n = n + 1 end
      end
      return n
      """

      assert {:ok, [20, 21]} = eval(budgeted(), ~S|return string.find("hello world, hello lua", "l+u")|)
      assert {:ok, [false, message]} = eval(budgeted(), "return pcall(function() #{code} end)")
      assert message =~ "instruction budget exceeded"
      assert {:ok, [5000]} = eval(Lua.new(max_instructions: 1_000_000), code)
    end

    test "pcall does not refund the budget" do
      code = """
      local ok, err = pcall(string.find, #{@lazy_bomb})
      local ok2, err2 = pcall(function() for _ = 1, 10 do end end)
      return ok, err, ok2, err2
      """

      assert {:ok, [false, err, false, err2]} = eval(budgeted(), code)
      assert err =~ "instruction budget exceeded"
      assert err2 =~ "instruction budget exceeded"
    end

    test "a gsub callback and the matcher share one tally" do
      gsub = ~S|string.gsub(string.rep("ab", 500), "%w", function(c) for _ = 1, 6 do end return c end)|
      loop = "for _ = 1, 5000 do end"

      assert {:ok, ["ok"]} = eval(budgeted(), "#{gsub} return 'ok'")
      assert {:ok, ["ok"]} = eval(budgeted(), "#{loop} return 'ok'")
      assert {:raised, message} = eval(budgeted(), "#{gsub} #{loop} return 'ok'")
      assert message =~ "instruction budget exceeded"
    end

    test "gsub callback effects survive the budget error" do
      code = ~S"""
      calls = 0
      local ok, err = pcall(string.gsub, string.rep("ab", 50000), "%w", function(c)
        calls = calls + 1
        return c
      end)
      return ok, err, calls
      """

      assert {:ok, [false, err, calls]} = eval(budgeted(), code)
      assert err =~ "instruction budget exceeded"
      assert calls > 0 and calls < 100_000
    end

    test ":infinity does not meter" do
      code = ~S|return string.find(string.rep("a", 25), "a*a*a*a*b")|
      assert {:ok, [false, message]} = eval(Lua.new(max_instructions: 100), "return pcall(function() #{code} end)")
      assert message =~ "instruction budget exceeded"
      assert {:ok, [nil]} = eval(Lua.new(), code)
    end
  end

  describe "realistic workloads" do
    test "log parsing" do
      line = "2024-05-01  12:34:56 [warn] request_id=a1b2c3 latency=42ms status=503 path=/api/v1/items\n"
      log = String.duplicate(line, 1000)

      code = ~s"""
      local log = string.rep(#{inspect(line)}, 1000)
      local total, ids = 0, 0
      for l in log:gmatch("[^\\n]+") do
        local status = l:match("status=(%d+)")
        local s, e = l:find("%[%a+%]")
        if l:match("request_id=(%w+)") then ids = ids + 1 end
        total = total + tonumber(status) + (e - s)
      end
      local squeezed = log:gsub("%s+", " ")
      local filled = ("${a}-${b}"):gsub("%${(%w+)}", {a = "x", b = "y"})
      return total, ids, #squeezed, filled
      """

      squeezed = byte_size(String.replace(log, ~r/\s+/, " "))
      assert {:ok, [508_000, 1000, ^squeezed, "x-y"]} = eval(Lua.new(max_instructions: 1_000_000), code)
    end

    test "a set test is constant time in its item count" do
      code = ~S"""
      local big = "[" .. string.rep("xyz", 100000) .. "a]+"
      local s, e = string.find(string.rep("a", 10000) .. "b", big)
      return s, e,
             string.match("ab_9-Z!", "[%a_%d]+"),
             string.match("ab_9-Z!", "[^%a_]+"),
             string.match("hello-world", "[a-f]+"),
             string.match("]x", "[]]"),
             string.match("a-b", "[a%-]+")
      """

      assert {:ok, [1, 10_000, "ab_9", "9-", "e", "]", "a-"]} = eval(Lua.new(max_instructions: 1_000_000), code)
    end
  end

  describe "structural limits" do
    test "more than 32 captures raises 'too many captures'" do
      for lua <- [Lua.new(), budgeted()] do
        assert {:ok, [false, message]} = eval(lua, ~S|return pcall(string.find, "abc", string.rep("()", 33))|)
        assert message =~ "too many captures"

        assert {:ok, [true, 1, 0 | positions]} = eval(lua, ~S|return pcall(string.find, "abc", string.rep("()", 32))|)
        assert positions == List.duplicate(1, 32)
      end
    end

    test "backtracking past 200 levels raises 'pattern too complex'" do
      deep = ~S|return pcall(string.match, string.rep("a", 200000), string.rep(".?", 200000))|
      shallow = ~S|return pcall(string.match, string.rep("a", 80), string.rep(".?", 80))|

      for lua <- [Lua.new(), Lua.new(max_instructions: 1_000_000)] do
        assert {:ok, [false, message]} = eval(lua, deep)
        assert message =~ "pattern too complex"

        assert {:ok, [true, match]} = eval(lua, shallow)
        assert match == String.duplicate("a", 80)
      end
    end

    test "plain characters spend no depth" do
      code = ~S|return #string.match(string.rep("a", 5000), string.rep("a", 5000))|
      assert {:ok, [5000]} = eval(Lua.new(), code)
    end

    test "a structural error keeps earlier gsub callback effects" do
      # Matches 1-3 are shallow; the 4th trips the depth limit.
      code = ~S"""
      seen = 0
      local subject = "xa xb xc x" .. string.rep("1", 300)
      local ok, err = pcall(string.gsub, subject, "x" .. string.rep("%d?", 300), function()
        seen = seen + 1
      end)
      return ok, err, seen
      """

      assert {:ok, [false, err, 3]} = eval(Lua.new(), code)
      assert err =~ "pattern too complex"
    end
  end
end
