defmodule Lua.VM.Stdlib.OsTest do
  use ExUnit.Case, async: true

  # Regression coverage for Lua 5.3 suite: all.lua line 57
  # (`local initclock = os.clock()`), which raised
  # "attempt to call a nil value (field 'clock' on global 'os')"
  # before the os library existed.

  describe "os library" do
    test "os.clock returns a non-negative number" do
      {[c], _} = Lua.eval!("return os.clock()")
      assert is_number(c)
      assert c >= 0
    end

    test "os.time with no args returns current epoch seconds" do
      {[t], _} = Lua.eval!("return os.time()")
      assert is_integer(t)
      assert t > 1_500_000_000
    end

    test "os.time builds an epoch from a date table (UTC)" do
      code = "return os.time({year=2000, month=1, day=1, hour=0, min=0, sec=0})"
      {[t], _} = Lua.eval!(code)
      assert t == 946_684_800
    end

    test "os.time_ms returns the current epoch in milliseconds" do
      {[t], _} = Lua.eval!("return os.time_ms()")
      assert is_integer(t)
      assert t > 1_500_000_000_000
    end

    test "os.time_us returns the current epoch in microseconds" do
      {[t], _} = Lua.eval!("return os.time_us()")
      assert is_integer(t)
      assert t > 1_500_000_000_000_000
    end

    test "os.time_ms and os.time_us share the same magnitude as os.time" do
      {[secs, ms, us], _} = Lua.eval!("return os.time(), os.time_ms(), os.time_us()")
      assert div(ms, 1000) in (secs - 2)..(secs + 2)
      assert div(us, 1_000_000) in (secs - 2)..(secs + 2)
    end

    test "os.difftime returns the difference in seconds" do
      {[d], _} = Lua.eval!("return os.difftime(10, 3)")
      assert d == 7.0
    end

    test "os.date formats with strftime directives" do
      code = ~S[return os.date("!%Y-%m-%d", 946684800)]
      {[s], _} = Lua.eval!(code)
      assert s == "2000-01-01"
    end

    test "os.date expands every directive and leaves the rest of the format alone" do
      # 946684800 is Saturday 2000-01-01 00:00:00 UTC.
      cases = [
        {~S|"!%c"|, "Sat Jan 01 00:00:00 2000"},
        {~S|"!%A %a %B %b"|, "Saturday Sat January Jan"},
        {~S|"!%y %j %p %x %X"|, "00 001 AM 01/01/00 00:00:00"},
        {~S|"![%H:%M:%S]"|, "[00:00:00]"},
        {~S|"!%Y%m%d"|, "20000101"},
        # `%%` is a literal percent, and does not start a directive with
        # the byte after it.
        {~S|"!%%"|, "%"},
        {~S|"!%%Y"|, "%Y"},
        {~S|"!"|, ""}
      ]

      for {format, expected} <- cases do
        assert {[^expected], _} = Lua.eval!("return os.date(#{format}, 946684800)")
      end
    end

    test "os.date with *t returns a broken-down time table" do
      code = """
      local t = os.date("!*t", 946684800)
      return t.year, t.month, t.day, t.hour, t.min, t.sec
      """

      {[year, month, day, hour, min, sec], _} = Lua.eval!(code)
      assert {year, month, day, hour, min, sec} == {2000, 1, 1, 0, 0, 0}
    end

    test "os.setlocale reports the C locale" do
      {[locale], _} = Lua.eval!(~S[return os.setlocale("C")])
      assert locale == "C"
    end

    test "os.getenv returns nil for an undefined variable when not sandboxed" do
      lua = Lua.new(sandboxed: [])
      {[v], _} = Lua.eval!(lua, ~S[return os.getenv("LUA_NONEXISTENT_VAR_XYZ")])
      assert v == nil
    end

    test "os.getenv is sandboxed by default" do
      assert_raise Lua.RuntimeException, ~r/os\.getenv.*sandboxed/, fn ->
        Lua.eval!(~S[return os.getenv("PATH")])
      end
    end
  end

  # Lua 5.3 §6.9: date-table fields passed to os.time need not be within their
  # valid ranges; they are normalised the way C mktime does.
  describe "os.time field normalization" do
    test "day = 0 is the last day of the previous month" do
      assert normalize("year=2026, month=9, day=0") == {2026, 8, 31, 12, 0, 0}
      assert normalize("year=2026, month=3, day=0") == {2026, 2, 28, 12, 0, 0}
      assert normalize("year=2028, month=3, day=0") == {2028, 2, 29, 12, 0, 0}
    end

    test "day = 0 of month 1 rolls back into December of the previous year" do
      assert normalize("year=2026, month=1, day=0") == {2025, 12, 31, 12, 0, 0}
    end

    test "month past December rolls into the next year" do
      assert normalize("year=2026, month=13, day=1") == {2027, 1, 1, 12, 0, 0}
      assert normalize("year=2026, month=12 + 1, day=0") == {2026, 12, 31, 12, 0, 0}
      assert normalize("year=2026, month=14, day=1") == {2027, 2, 1, 12, 0, 0}
      assert normalize("year=2026, month=24, day=1") == {2027, 12, 1, 12, 0, 0}
      assert normalize("year=2026, month=25, day=0") == {2027, 12, 31, 12, 0, 0}
      assert normalize("year=2026, month=25, day=1") == {2028, 1, 1, 12, 0, 0}
      assert normalize("year=2026, month=100, day=1") == {2034, 4, 1, 12, 0, 0}
    end

    test "month below January rolls into the previous year" do
      assert normalize("year=2026, month=0, day=1") == {2025, 12, 1, 12, 0, 0}
      assert normalize("year=2026, month=-1, day=1") == {2025, 11, 1, 12, 0, 0}
      assert normalize("year=2026, month=-13, day=1") == {2024, 11, 1, 12, 0, 0}
    end

    test "day past the end of the month overflows into the next month" do
      assert normalize("year=2026, month=2, day=30") == {2026, 3, 2, 12, 0, 0}
      assert normalize("year=2028, month=2, day=30") == {2028, 3, 1, 12, 0, 0}
      assert normalize("year=2026, month=1, day=32") == {2026, 2, 1, 12, 0, 0}
      assert normalize("year=2026, month=1, day=400") == {2027, 2, 4, 12, 0, 0}
    end

    test "negative day counts back across months and years" do
      assert normalize("year=2026, month=1, day=-40") == {2025, 11, 21, 12, 0, 0}
    end

    test "time fields overflow and underflow across days" do
      assert normalize("year=2026, month=12, day=31, hour=25") == {2027, 1, 1, 1, 0, 0}
      assert normalize("year=2026, month=1, day=1, hour=0, min=0, sec=-10") == {2025, 12, 31, 23, 59, 50}
      assert normalize("year=2026, month=1, day=1, hour=0, min=90") == {2026, 1, 1, 1, 30, 0}
    end

    test "in-range fields are unchanged" do
      assert normalize("year=2000, month=1, day=1, hour=0, min=0, sec=0") == {2000, 1, 1, 0, 0, 0}
    end
  end

  describe "os.time field validation" do
    test "sec = 60 rolls into the next minute" do
      assert normalize("year=2026, month=1, day=1, hour=0, min=0, sec=60") == {2026, 1, 1, 0, 1, 0}
    end

    test "years past 9999 are computed, not rejected" do
      assert time_of("year=9999, month=13, day=1, hour=0") == 253_402_300_800
    end

    for field <- ~w(year month day hour min sec) do
      test "#{field} beyond the C int range is out-of-bound" do
        base = %{"year" => 2026, "month" => 1, "day" => 1, "hour" => 0, "min" => 0, "sec" => 0}

        for huge <- ["2^31 + 2000", "2^40", "2^60", "-2^40", "-2^62", "math.maxinteger", "math.mininteger"] do
          fields = base |> Map.put("#{unquote(field)}", huge) |> fields_to_lua()

          assert {:error, msg} = time_error(fields)
          assert msg =~ "field '#{unquote(field)}' is out-of-bound"
        end
      end
    end

    test "the C int boundary is inclusive, with the year and month offsets" do
      # year is checked after subtracting 1900, month after subtracting 1.
      assert {:ok, _} = time_error("year=2^31 - 1 + 1900, month=1, day=1")
      assert {:error, msg} = time_error("year=2^31 + 1900, month=1, day=1")
      assert msg =~ "field 'year' is out-of-bound"
      assert {:ok, _} = time_error("year=-2^31 + 1900, month=1, day=1")
      assert {:error, msg} = time_error("year=-2^31 + 1899, month=1, day=1")
      assert msg =~ "field 'year' is out-of-bound"
      assert {:ok, _} = time_error("year=2026, month=2^31, day=1")
      assert {:error, msg} = time_error("year=2026, month=2^31 + 1, day=1")
      assert msg =~ "field 'month' is out-of-bound"
      assert {:ok, _} = time_error("year=2026, month=1, day=2^31 - 1")
      assert {:error, msg} = time_error("year=2026, month=1, day=2^31")
      assert msg =~ "field 'day' is out-of-bound"
    end

    test "results stay within 64 bits for the largest accepted fields" do
      for fields <- [
            "year=2^31 - 1 + 1900, month=2^31, day=2^31 - 1, hour=2^31 - 1, min=2^31 - 1, sec=2^31 - 1",
            "year=-2^31 + 1900, month=-2^31 + 1, day=-2^31, hour=-2^31, min=-2^31, sec=-2^31"
          ] do
        {[t], _} = Lua.eval!("return os.time({#{fields}})")
        assert is_integer(t)
        assert t >= -9_223_372_036_854_775_808 and t <= 9_223_372_036_854_775_807
      end
    end

    test "fields with no integer representation raise 'not an integer'" do
      for value <- ["1.5", "1/0", "-1/0", "0/0", "'x'", "{}", "true", "1e308"] do
        assert {:error, msg} = time_error("year=2026, month=1, day=1, hour=#{value}")
        assert msg =~ "field 'hour' is not an integer"
      end

      assert {:error, msg} = time_error("year=2026, month=1.5, day=1")
      assert msg =~ "field 'month' is not an integer"
    end

    test "floats with an exact integer value and numeric strings are accepted" do
      assert time_of("year=2026.0, month=1, day=1, hour=3.0") == time_of("year=2026, month=1, day=1, hour=3")
      assert time_of("year=2026, month=1, day=1, hour='3'") == time_of("year=2026, month=1, day=1, hour=3")
      assert time_of("year='2026', month='1', day='1'") == time_of("year=2026, month=1, day=1")
    end

    test "a missing required field still raises 'missing'" do
      assert {:error, msg} = time_error("month=1, day=1")
      assert msg =~ "field 'year' missing"
    end
  end

  defp fields_to_lua(map), do: Enum.map_join(map, ", ", fn {k, v} -> "#{k}=#{v}" end)

  defp time_of(fields) do
    {[t], _} = Lua.eval!("return os.time({#{fields}})")
    t
  end

  # Runs os.time under pcall so the Lua error message is available as a string.
  defp time_error(fields) do
    case Lua.eval!("return pcall(os.time, {#{fields}})") do
      {[true, _], _} -> {:ok, nil}
      {[false, msg], _} -> {:error, msg}
    end
  end

  defp normalize(fields) do
    code = """
    local t = os.date("!*t", os.time({#{fields}}))
    return t.year, t.month, t.day, t.hour, t.min, t.sec
    """

    {[year, month, day, hour, min, sec], _} = Lua.eval!(code)
    {year, month, day, hour, min, sec}
  end
end
