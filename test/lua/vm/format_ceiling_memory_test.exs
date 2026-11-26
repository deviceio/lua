defmodule Lua.VM.FormatCeilingMemoryTest do
  @moduledoc """
  Pins that `string.format` refuses a result over `:max_string_bytes` while it
  builds it, not after. A large `%f` and `%q` each make a fresh
  binary per conversion, so a check that waits for the end lets a script
  allocate many times the ceiling first.

  The assertion is on the node's binary memory, which other tests also move,
  so this module is not async and the bound is generous: the failing
  behavior grows by several megabytes at a 64 KiB ceiling.
  """
  use ExUnit.Case, async: false

  @ceiling 64 * 1024
  @allowed_growth 512 * 1024

  cases = [
    {"a large float", ~s|
      local t = {} for i = 1, 3000 do t[i] = 1e308 end
      return string.format(string.rep("%99.99f", 3000), table.unpack(t))|},
    {"%q of a string at the ceiling", ~s|
      local s = string.rep("\\1", 64 * 1024)
      local t = {} for i = 1, 40 do t[i] = s end
      return string.format(string.rep("%q", 40), table.unpack(t))|}
  ]

  for {name, code} <- cases do
    test "string.format refuses #{name} before it builds the rest", _ do
      {message, growth} = measure(unquote(code))

      assert message =~ "resulting string too large"
      assert growth < @allowed_growth, "binary memory grew #{div(growth, 1024)} KiB at a 64 KiB ceiling"
    end
  end

  defp measure(code) do
    lua = Lua.new(max_string_bytes: @ceiling)
    :erlang.garbage_collect()
    base = :erlang.memory(:binary)
    parent = self()
    sampler = spawn_link(fn -> sample(parent, base) end)

    message =
      try do
        Lua.eval!(lua, code)
        flunk("expected the call to be refused")
      rescue
        e in ExUnit.AssertionError -> reraise e, __STACKTRACE__
        e -> Exception.message(e)
      end

    send(sampler, :stop)

    peak =
      receive do
        {:peak, peak} -> peak
      end

    {message, peak - base}
  end

  defp sample(parent, peak) do
    receive do
      :stop -> send(parent, {:peak, peak})
    after
      1 -> sample(parent, max(peak, :erlang.memory(:binary)))
    end
  end
end
