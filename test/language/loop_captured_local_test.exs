defmodule Lua.Language.LoopCapturedLocalTest do
  @moduledoc """
  A local declared outside a loop and written inside it before a closure
  captures it must show the closure the latest value, as PUC-Lua does.
  """
  use ExUnit.Case, async: true

  defp run(code), do: elem(Lua.eval!(Lua.new(sandboxed: []), code), 0)

  describe "write before the closure is created" do
    test "numeric for" do
      assert ["1,2"] =
               run(~S"""
               local x = 0
               local out = {}
               for i = 1, 2 do
                 x = i
                 local g = function() return x end
                 out[i] = g()
               end
               return out[1] .. "," .. out[2]
               """)
    end

    test "numeric for inside a function" do
      assert ["1,2"] =
               run(~S"""
               local function f()
                 local x = 0
                 local out = {}
                 for i = 1, 2 do
                   x = i
                   local g = function() return x end
                   out[i] = g()
                 end
                 return out[1] .. "," .. out[2]
               end
               return f()
               """)
    end

    test "generic for" do
      assert ["a,b"] =
               run(~S"""
               local x = ""
               local out = {}
               for i, v in ipairs({"a", "b"}) do
                 x = v
                 local g = function() return x end
                 out[i] = g()
               end
               return out[1] .. "," .. out[2]
               """)
    end

    test "while" do
      assert ["1,2"] =
               run(~S"""
               local x, n = 0, 0
               local out = {}
               while n < 2 do
                 n = n + 1
                 x = n
                 local g = function() return x end
                 out[n] = g()
               end
               return out[1] .. "," .. out[2]
               """)
    end

    test "while, written in the condition" do
      assert ["1,2"] =
               run(~S"""
               local x = 0
               local out = {}
               local function bump() x = x + 1; return x <= 2 end
               local n = 0
               while bump() do
                 n = n + 1
                 local y = x
                 local g = function() return x + y * 0 end
                 out[n] = g()
               end
               return out[1] .. "," .. out[2]
               """)
    end

    test "repeat" do
      assert ["1,2"] =
               run(~S"""
               local x, n = 0, 0
               local out = {}
               repeat
                 n = n + 1
                 x = n
                 local g = function() return x end
                 out[n] = g()
               until n == 2
               return out[1] .. "," .. out[2]
               """)
    end

    test "goto loop" do
      assert ["1,2"] =
               run(~S"""
               local x, n = 0, 0
               local out = {}
               ::top::
               n = n + 1
               x = n
               local g = function() return x end
               out[n] = g()
               if n < 2 then goto top end
               return out[1] .. "," .. out[2]
               """)
    end

    test "goto loop where the local is declared before the label in the same block" do
      assert ["1,2"] =
               run(~S"""
               local function f()
                 local n = 0
                 local x = 0
                 local out = {}
                 ::top::
                 n = n + 1
                 x = n
                 out[n] = (function() return x end)()
                 if n < 2 then goto top end
                 return out[1] .. "," .. out[2]
               end
               return f()
               """)
    end

    test "local declared in an outer loop body, written in an inner loop" do
      assert ["1,2,3,4"] =
               run(~S"""
               local out = {}
               for a = 1, 2 do
                 local x = 0
                 for b = 1, 2 do
                   x = (a - 1) * 2 + b
                   local g = function() return x end
                   out[#out + 1] = g()
                 end
               end
               return table.concat(out, ",")
               """)
    end
  end

  describe "write after the closure is created" do
    test "numeric for" do
      assert ["1,2"] =
               run(~S"""
               local x = 0
               local out = {}
               for i = 1, 2 do
                 local g = function() return x end
                 x = i
                 out[i] = g()
               end
               return out[1] .. "," .. out[2]
               """)
    end

    test "generic for" do
      assert ["a,b"] =
               run(~S"""
               local x = ""
               local out = {}
               for i, v in ipairs({"a", "b"}) do
                 local g = function() return x end
                 x = v
                 out[i] = g()
               end
               return out[1] .. "," .. out[2]
               """)
    end

    test "while" do
      assert ["1,2"] =
               run(~S"""
               local x, n = 0, 0
               local out = {}
               while n < 2 do
                 n = n + 1
                 local g = function() return x end
                 x = n
                 out[n] = g()
               end
               return out[1] .. "," .. out[2]
               """)
    end

    test "repeat" do
      assert ["1,2"] =
               run(~S"""
               local x, n = 0, 0
               local out = {}
               repeat
                 n = n + 1
                 local g = function() return x end
                 x = n
                 out[n] = g()
               until n == 2
               return out[1] .. "," .. out[2]
               """)
    end

    test "goto loop" do
      assert ["1,2"] =
               run(~S"""
               local x, n = 0, 0
               local out = {}
               ::top::
               n = n + 1
               local g = function() return x end
               x = n
               out[n] = g()
               if n < 2 then goto top end
               return out[1] .. "," .. out[2]
               """)
    end
  end

  describe "closures sharing and outliving the loop" do
    test "a closure made in an earlier iteration sees later writes" do
      assert ["3,3"] =
               run(~S"""
               local x = 0
               local fs = {}
               for i = 1, 2 do
                 x = i
                 fs[i] = function() return x end
               end
               x = 3
               return fs[1]() .. "," .. fs[2]()
               """)
    end

    test "a closure can write the local the loop also writes" do
      assert ["1,10,2,20"] =
               run(~S"""
               local x = 0
               local out = {}
               for i = 1, 2 do
                 x = i
                 local set = function(v) x = v end
                 out[#out + 1] = x
                 set(i * 10)
                 out[#out + 1] = x
               end
               return table.concat(out, ",")
               """)
    end

    test "nested closures" do
      assert ["1,2"] =
               run(~S"""
               local x = 0
               local out = {}
               for i = 1, 2 do
                 x = i
                 local g = function()
                   return function() return x end
                 end
                 out[i] = g()()
               end
               return out[1] .. "," .. out[2]
               """)
    end

    test "nested closures, write between the two levels" do
      assert ["1,2"] =
               run(~S"""
               local x = 0
               local out = {}
               for i = 1, 2 do
                 local g = function()
                   x = i
                   return function() return x end
                 end
                 out[i] = g()()
               end
               return out[1] .. "," .. out[2]
               """)
    end

    test "a loop variable is still fresh for each iteration" do
      assert ["1,2"] =
               run(~S"""
               local fs = {}
               for i = 1, 2 do
                 fs[i] = function() return i end
               end
               return fs[1]() .. "," .. fs[2]()
               """)
    end
  end

  describe "function declarations assigning a captured local" do
    test "function f() in a loop before a closure captures f" do
      assert run("""
             local f
             for i = 1, 1 do
               function f() return 42 end
               local g = function() return f end
               return g()()
             end
             """) == [42]
    end
  end
end
