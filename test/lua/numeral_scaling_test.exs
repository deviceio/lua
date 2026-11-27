defmodule Lua.NumeralScalingTest do
  @moduledoc """
  Pins that converting a numeral takes time linear in its length: on a numeral
  four times as long, a quadratic conversion would take about 16x as long.

  Not async: CPU contention preempts the longer conversions more often, which
  skews the ratio.
  """
  use ExUnit.Case, async: false

  @max_linear_ratio 8
  @attempts 3
  @runs_per_attempt 25

  describe "the lexer" do
    test "converts a long decimal integer literal in linear time" do
      assert_linear(&("return " <> String.duplicate("9", &1)), &assert_parses/1, 100_000)
    end

    test "converts a long hexadecimal integer literal in linear time" do
      assert_linear(&("return 0x" <> String.duplicate("f", &1)), &assert_parses/1, 100_000)
    end
  end

  describe "tonumber" do
    test "converts a long decimal string in linear time" do
      assert_linear(&state_with_s(String.duplicate("9", &1)), &assert_returns_number(&1, "return tonumber(s)"), 250_000)
    end

    test "converts a long string in base 36 in linear time" do
      assert_linear(
        &state_with_s(String.duplicate("z", &1)),
        &assert_returns_number(&1, "return tonumber(s, 36)"),
        100_000
      )
    end

    test "converts a long hexadecimal string in linear time" do
      assert_linear(
        &state_with_s("0x" <> String.duplicate("f", &1)),
        &assert_returns_number(&1, "return tonumber(s)"),
        250_000
      )
    end
  end

  defp state_with_s(numeral), do: Lua.set!(Lua.new(), [:s], numeral)

  defp assert_parses(source), do: assert({:ok, _chunk} = Lua.parse_chunk(source))

  defp assert_returns_number(lua, code) do
    assert {[number], _lua} = Lua.eval!(lua, code)
    assert is_number(number)
  end

  # Each attempt keeps the fastest of alternating small and large runs, so a
  # stray GC or a busy scheduler does not decide the ratio.
  defp assert_linear(build_input, convert, size) do
    small_input = build_input.(size)
    large_input = build_input.(4 * size)

    ratios =
      Enum.reduce_while(1..@attempts, [], fn _attempt, ratios ->
        record_ratio(ratio(convert, small_input, large_input), ratios)
      end)

    assert hd(ratios) < @max_linear_ratio,
           "a numeral 4x as long took #{inspect(Enum.map(ratios, &Float.round(&1, 1)))}x as long to convert"
  end

  defp record_ratio(ratio, ratios) when ratio < @max_linear_ratio, do: {:halt, [ratio | ratios]}
  defp record_ratio(ratio, ratios), do: {:cont, [ratio | ratios]}

  defp ratio(convert, small_input, large_input) do
    {small_times, large_times} =
      Enum.unzip(for _run <- 1..@runs_per_attempt, do: {time(convert, small_input), time(convert, large_input)})

    Enum.min(large_times) / max(Enum.min(small_times), 1)
  end

  defp time(convert, input), do: elem(:timer.tc(fn -> convert.(input) end), 0)
end
