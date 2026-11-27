defmodule Lua.NumeralTest do
  use ExUnit.Case, async: true

  alias Lua.Numeral

  describe "parse/1" do
    test "a decimal integer stays an integer until it overflows the signed 64-bit range" do
      assert Numeral.parse("9223372036854775807") === {:ok, 9_223_372_036_854_775_807}
      assert Numeral.parse("-9223372036854775808") === {:ok, -9_223_372_036_854_775_808}
      assert Numeral.parse("9223372036854775808") === {:ok, 9.223372036854776e18}
      assert Numeral.parse("-9223372036854775809") === {:ok, -9.223372036854776e18}
      assert Numeral.parse(String.duplicate("0", 1000) <> "42") === {:ok, 42}
    end

    test "a hexadecimal integer wraps modulo 2^64" do
      assert Numeral.parse("0x1" <> String.duplicate("0", 16)) === {:ok, 0}
      assert Numeral.parse("-0x" <> String.duplicate("f", 16)) === {:ok, 1}
      assert Numeral.parse("0x" <> String.duplicate("0", 1000) <> "a") === {:ok, 10}
    end

    test "a long decimal mantissa rounds as if every digit were kept" do
      halfway = "9007199254740993." <> String.duplicate("0", 1000)

      assert Numeral.parse(halfway) === {:ok, 9_007_199_254_740_992.0}
      assert Numeral.parse(halfway <> "1") === {:ok, 9_007_199_254_740_994.0}
      assert Numeral.parse("0." <> String.duplicate("0", 300) <> "1") === {:ok, 1.0e-301}
      assert Numeral.parse("1" <> String.duplicate("0", 400) <> "e-400") === {:ok, 1.0}
    end

    test "a hexadecimal float rounds half to even, through subnormals and overflow" do
      assert Numeral.parse("0x1.00000000000008") === {:ok, 1.0}
      assert Numeral.parse("0x1.00000000000018") === {:ok, 1.0000000000000004}
      assert Numeral.parse("0x1.00000000000008" <> String.duplicate("0", 100) <> "1") === {:ok, 1.0000000000000002}
      assert Numeral.parse("0x1p-1074") === {:ok, 5.0e-324}
      assert Numeral.parse("0x3p-1076") === {:ok, 5.0e-324}
      assert Numeral.parse("0x1p-1075") === {:ok, 0.0}
      assert Numeral.parse("0x0.fffffffffffff8p-1022") === {:ok, 2.2250738585072014e-308}
      assert Numeral.parse("0x1.fffffffffffffp1023") === {:ok, 1.7976931348623157e308}
      assert Numeral.parse("0x1.fffffffffffff8p1023") === {:ok, 1.0e308}
    end

    test "an exponent of any size gives the infinity stand-in or zero" do
      huge_exponent = String.duplicate("9", 50_000)

      assert Numeral.parse("1e99999") === {:ok, 1.0e308}
      assert Numeral.parse("-1e99999") === {:ok, -1.0e308}
      assert Numeral.parse("1.5e309") === {:ok, 1.0e308}
      assert Numeral.parse("1e" <> huge_exponent) === {:ok, 1.0e308}
      assert Numeral.parse("1e-99999") === {:ok, 0.0}
      assert Numeral.parse("1e-" <> huge_exponent) === {:ok, 0.0}
      assert Numeral.parse("0e" <> huge_exponent) === {:ok, 0.0}
      assert Numeral.parse("0x1p" <> huge_exponent) === {:ok, 1.0e308}
      assert Numeral.parse("0x.1p-99999") === {:ok, 0.0}
    end

    test "rejects anything that is not exactly one numeral" do
      for malformed <-
            ~w(- . e1 .e1 1e 1e+ 1.0e+ 0x 0x. 0x.p1 0x1p 0x1p+ 0x5p+-2 --1 +-1 1..2 0x3.3.3 00x2 23x inf nan) ++
              ["", " 1", "1 ", "1\0"] do
        assert Numeral.parse(malformed) == :error, "expected #{inspect(malformed)} to be rejected"
      end
    end
  end

  describe "parse_integer/2" do
    test "accumulates modulo 2^64 and rejects digits outside the base" do
      assert Numeral.parse_integer("-1z", 36) === {:ok, -71}
      assert Numeral.parse_integer(String.duplicate("z", 1000), 36) === {:ok, -1}
      assert Numeral.parse_integer("1" <> String.duplicate("0", 64), 2) === {:ok, 0}

      for {malformed, base} <- [{"", 10}, {"-", 10}, {"--5", 10}, {"8", 8}, {"1 0", 10}, {"0x10", 16}] do
        assert Numeral.parse_integer(malformed, base) == :error
      end
    end
  end
end
