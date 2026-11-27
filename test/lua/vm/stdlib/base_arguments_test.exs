defmodule Lua.VM.Stdlib.BaseArgumentsTest do
  use ExUnit.Case, async: true

  for {call, message} <- [
        {"rawset(1, 2, 3)", "bad argument #1 to 'rawset' (table expected, got number)"},
        {"rawset({}, 1)", "bad argument #3 to 'rawset' (value expected)"},
        {"rawget('x', 1)", "bad argument #1 to 'rawget' (table expected, got string)"},
        {"rawget({})", "bad argument #2 to 'rawget' (value expected)"},
        {"rawequal(1)", "bad argument #2 to 'rawequal' (value expected)"},
        {"setmetatable({})", "bad argument #2 to 'setmetatable' (nil or table expected)"},
        {"getmetatable()", "bad argument #1 to 'getmetatable' (value expected)"},
        {"next(1)", "bad argument #1 to 'next' (table expected, got number)"},
        {"tostring()", "bad argument #1 to 'tostring' (value expected)"},
        {"tonumber()", "bad argument #1 to 'tonumber' (value expected)"},
        {"tonumber(10, 16)", "bad argument #1 to 'tonumber' (string expected, got number)"},
        {"tonumber('10', 99)", "bad argument #2 to 'tonumber' (base out of range)"},
        {"tonumber('10', 1.5)", "bad argument #2 to 'tonumber' (number has no integer representation)"},
        {"select(1.5, 'a')", "bad argument #1 to 'select' (number has no integer representation)"},
        {"select(-2, 'a')", "bad argument #1 to 'select' (index out of range)"}
      ] do
    test "#{call} raises #{message}" do
      assert {[false, unquote(message)], _} = Lua.eval!("return pcall(function() return #{unquote(call)} end)")
    end
  end

  test "setmetatable ignores arguments past the metatable" do
    assert {[true], _} = Lua.eval!("local t = {} return setmetatable(t, {}, 'extra') == t")
  end

  test "select accepts a float with an integer value as the index" do
    assert {["b"], _} = Lua.eval!("return select(2.0, 'a', 'b')")
  end
end
