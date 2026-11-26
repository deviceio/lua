defmodule Lua.VM.BuilderCeilingTest do
  @moduledoc """
  Pins `max_string_bytes` on the builders that assemble a string from many
  arguments or frames: `print`, `string.char`, `utf8.char` and
  `debug.traceback`, plus the `string.format` error order under a ceiling
  smaller than a conversion's width.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defp eval_error(ceiling, code) do
    lua = Lua.new(max_string_bytes: ceiling)

    {[false, message], _} = Lua.eval!(lua, "return pcall(function() #{code} end)")
    message
  end

  describe "print" do
    test "refuses a line over the ceiling and writes nothing" do
      code = ~s|local s = string.rep("x", 1024) local t = {} for i = 1, 64 do t[i] = s end print(table.unpack(t))|

      output =
        capture_io(fn ->
          assert eval_error(2048, code) =~ "resulting string too large"
        end)

      assert output == ""
    end

    test "counts the tab separators" do
      # "ab" and "cd" joined by a tab make a 5-byte line.
      output = capture_io(fn -> Lua.eval!(Lua.new(max_string_bytes: 5), ~s|print("ab", "cd")|) end)
      assert output == "ab\tcd\n"

      capture_io(fn ->
        assert eval_error(4, ~s|print("ab", "cd")|) =~ "resulting string too large"
      end)
    end

    test "prints normally under the default ceiling" do
      assert capture_io(fn -> Lua.eval!(Lua.new(), ~s|print("a", 1, nil)|) end) == "a\t1\tnil\n"
    end
  end

  describe "string.char" do
    test "refuses more bytes than the ceiling" do
      code = "local t = {} for i = 1, 100 do t[i] = 65 end return string.char(table.unpack(t))"
      assert eval_error(64, code) =~ "resulting string too large"
    end

    test "allows exactly the ceiling and keeps its own argument errors" do
      lua = Lua.new(max_string_bytes: 3)
      assert {["ABC"], _} = Lua.eval!(lua, "return string.char(65, 66, 67)")
      assert eval_error(1, "return string.char(65, 66, 'x')") =~ "number expected"
    end
  end

  describe "utf8.char" do
    test "counts encoded bytes, not arguments" do
      code = "local t = {} for i = 1, 100 do t[i] = 0x10FFFF end return utf8.char(table.unpack(t))"
      assert eval_error(64, code) =~ "resulting string too large"
    end

    test "allows exactly the ceiling" do
      lua = Lua.new(max_string_bytes: 8)
      assert {[8], _} = Lua.eval!(lua, "return #utf8.char(0x10FFFF, 0x10FFFF)")
      assert eval_error(7, "return utf8.char(0x10FFFF, 0x10FFFF)") =~ "resulting string too large"
    end
  end

  describe "debug.traceback" do
    test "counts the message and the frames" do
      assert eval_error(64, ~s|return debug.traceback(string.rep("x", 64))|) =~ "resulting string too large"
    end

    test "refuses a deep stack before building the whole traceback" do
      code = "local function f(n) if n == 0 then return debug.traceback() end return (f(n - 1)) end return f(2000)"
      assert eval_error(4096, code) =~ "resulting string too large"
    end

    test "returns a short traceback under the default ceiling" do
      assert {[tb], _} = Lua.eval!(Lua.new(), ~s|return debug.traceback("msg")|)
      assert tb =~ "msg\nstack traceback:"
    end
  end

  describe "string.format under a tiny ceiling" do
    test "a bad argument reports its own error, not the size" do
      assert eval_error(10, ~s|return string.format("%99d", "abc")|) =~ "number expected"
      assert eval_error(10, ~s|return string.format("%99z", 1)|) =~ "invalid option"
    end

    test "a wide conversion is still refused" do
      assert eval_error(10, ~s|return string.format("%99d", 1)|) =~ "resulting string too large"
    end
  end
end
