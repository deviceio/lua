defmodule Lua.Numeral do
  @moduledoc """
  Converts Lua 5.3 numerals to numbers in time linear in their length, for the
  lexer and every string-to-number coercion.

  A decimal integer numeral that overflows the signed 64-bit range becomes a
  float, a hexadecimal integer wraps modulo 2^64, and a float past the double
  range becomes `1.0e308`, the VM's stand-in for infinity.
  """

  import Bitwise

  @uint32_mask 0xFFFFFFFF
  @uint64_mask 0xFFFFFFFFFFFFFFFF
  @uint64_modulus 0x10000000000000000
  @sign_bit 0x8000000000000000
  @max_int 0x7FFFFFFFFFFFFFFF
  @min_int -0x8000000000000000
  @int64_max_decimal_digits 19
  @uint64_hex_digits 16

  @huge 1.0e308
  @infinity_bits 0x7FF0000000000000
  @double_precision 53
  @double_fraction_bits @double_precision - 1
  @smallest_subnormal_exponent -1074

  # Exponents of `0.<digits>e<exponent>` past which the value overflows or
  # underflows a double whatever the digits.
  @max_decimal_exponent 310
  @min_decimal_exponent -330

  # A midpoint between two adjacent doubles has at most 767 significant
  # decimal digits, so one nonzero sticky digit stands in for all later ones.
  @max_decimal_mantissa_digits 800
  # Sixteen hex digits hold at least 61 significant bits: a 53-bit mantissa
  # plus its rounding bit, then the sticky digit.
  @max_hex_mantissa_digits 16
  @max_kept_mantissa_bits 4 * (@max_hex_mantissa_digits + 1)

  # Past any numeral's digit count, so a saturated exponent still over- or
  # underflows whatever the digits.
  @exponent_cap 1_000_000_000_000_000

  @nonzero_digits ~w(1 2 3 4 5 6 7 8 9 a b c d e f A B C D E F)
  @not_a_digit 36

  @doc "Converts a numeral with an optional sign to a number."
  @spec parse(binary()) :: {:ok, number()} | :error
  def parse(<<?-, numeral::binary>>), do: parse_unsigned(numeral, :negative)
  def parse(<<?+, numeral::binary>>), do: parse_unsigned(numeral, :positive)
  def parse(numeral) when is_binary(numeral), do: parse_unsigned(numeral, :positive)

  @doc "Converts digits in `base` with an optional sign to an integer, wrapping modulo 2^64."
  @spec parse_integer(binary(), 2..36) :: {:ok, integer()} | :error
  def parse_integer(<<?-, digits::binary>>, base), do: parse_base_digits(digits, base, :negative)
  def parse_integer(<<?+, digits::binary>>, base), do: parse_base_digits(digits, base, :positive)
  def parse_integer(digits, base) when is_binary(digits), do: parse_base_digits(digits, base, :positive)

  defp parse_unsigned(<<?0, x, numeral::binary>>, sign) when x in [?x, ?X], do: parse_digits(numeral, :hex, sign)
  defp parse_unsigned(numeral, sign), do: parse_digits(numeral, :decimal, sign)

  defp parse_digits(numeral, radix, sign) do
    {integer_digits, rest} = take_digits(numeral, radix)
    parse_after_integer_digits(integer_digits, rest, radix, sign)
  end

  defp parse_after_integer_digits(integer_digits, "", radix, sign) when integer_digits != "" do
    {:ok, integer_value(integer_digits, radix, sign)}
  end

  defp parse_after_integer_digits(integer_digits, "." <> rest, radix, sign) do
    {fraction_digits, exponent_part} = take_digits(rest, radix)
    parse_float(integer_digits, fraction_digits, exponent_part, radix, sign)
  end

  defp parse_after_integer_digits(integer_digits, exponent_part, radix, sign) do
    parse_float(integer_digits, "", exponent_part, radix, sign)
  end

  defp parse_float(integer_digits, fraction_digits, exponent_part, radix, sign)
       when integer_digits != "" or fraction_digits != "" do
    with {:ok, exponent} <- exponent(exponent_part, radix) do
      digits = trim_leading_zeros(integer_digits <> fraction_digits)
      {:ok, signed(float_value(digits, byte_size(fraction_digits), exponent, radix), sign)}
    end
  end

  defp parse_float(_integer_digits, _fraction_digits, _exponent_part, _radix, _sign), do: :error

  defp integer_value(digits, :decimal, sign) do
    significant_digits = trim_leading_zeros(digits)

    case to_int64(significant_digits, sign) do
      {:ok, integer} -> integer
      :overflow -> signed(decimal_float(significant_digits, 0), sign)
    end
  end

  defp integer_value(digits, :hex, sign) do
    low_digit_count = min(byte_size(digits), @uint64_hex_digits)

    digits
    |> binary_part(byte_size(digits) - low_digit_count, low_digit_count)
    |> :erlang.binary_to_integer(16)
    |> signed(sign)
    |> wrap_int64()
  end

  defp to_int64("", _sign), do: {:ok, 0}

  defp to_int64(digits, sign) when byte_size(digits) <= @int64_max_decimal_digits do
    case signed(:erlang.binary_to_integer(digits), sign) do
      integer when integer >= @min_int and integer <= @max_int -> {:ok, integer}
      _integer -> :overflow
    end
  end

  defp to_int64(_digits, _sign), do: :overflow

  defp float_value(digits, fraction_size, exponent, :decimal), do: decimal_float(digits, exponent - fraction_size)

  defp float_value(digits, fraction_size, exponent, :hex) do
    kept = truncate_with_sticky_digit(digits, @max_hex_mantissa_digits)
    binary_exponent = exponent + 4 * (byte_size(digits) - fraction_size - byte_size(kept))
    round_to_double(hex_to_integer(kept), binary_exponent)
  end

  # `digits` has no leading zero and stands for `digits * 10^scale`.
  defp decimal_float("", _scale), do: 0.0
  defp decimal_float(digits, scale), do: scientific_float(digits, byte_size(digits) + scale)

  defp scientific_float(_digits, exponent) when exponent > @max_decimal_exponent, do: @huge
  defp scientific_float(_digits, exponent) when exponent < @min_decimal_exponent, do: 0.0

  defp scientific_float(digits, exponent) do
    kept = truncate_with_sticky_digit(digits, @max_decimal_mantissa_digits)
    binary_to_float_or_huge("0." <> kept <> "e" <> Integer.to_string(exponent))
  end

  # The literal is well formed, so Erlang refuses it only when it overflows.
  defp binary_to_float_or_huge(literal) do
    :erlang.binary_to_float(literal)
  rescue
    ArgumentError -> @huge
  end

  defp hex_to_integer(""), do: 0
  defp hex_to_integer(digits), do: :erlang.binary_to_integer(digits, 16)

  # Rounds `mantissa * 2^exponent` half to even onto the double grid. A carry
  # out of the mantissa moves into the exponent field, as IEEE 754 rounding does.
  defp round_to_double(0, _exponent), do: 0.0

  defp round_to_double(mantissa, exponent) do
    shift = max(bit_length(mantissa, 0) - @double_precision, @smallest_subnormal_exponent - exponent)
    biased_exponent = exponent + shift - @smallest_subnormal_exponent
    float_from_bits(bsl(biased_exponent, @double_fraction_bits) + shift_right_rounded(mantissa, shift))
  end

  defp float_from_bits(bits) when bits >= @infinity_bits, do: @huge

  defp float_from_bits(bits) do
    <<float::float-64>> = <<bits::64>>
    float
  end

  defp shift_right_rounded(mantissa, shift) when shift <= 0, do: bsl(mantissa, -shift)
  # Rounds to zero without building 2^shift, which a saturated exponent makes huge.
  defp shift_right_rounded(_mantissa, shift) when shift > @max_kept_mantissa_bits, do: 0

  defp shift_right_rounded(mantissa, shift) do
    quotient = bsr(mantissa, shift)
    round_half_even(quotient, mantissa - bsl(quotient, shift), bsl(1, shift - 1))
  end

  defp round_half_even(quotient, remainder, half) when remainder > half, do: quotient + 1
  defp round_half_even(quotient, half, half) when band(quotient, 1) == 1, do: quotient + 1
  defp round_half_even(quotient, _remainder, _half), do: quotient

  defp bit_length(0, count), do: count
  defp bit_length(value, count), do: bit_length(bsr(value, 1), count + 1)

  # A nonzero digit among the dropped ones becomes a trailing 1, which keeps
  # the value strictly between the same two rounding boundaries.
  defp truncate_with_sticky_digit(digits, max_digits) when byte_size(digits) <= max_digits, do: digits

  defp truncate_with_sticky_digit(digits, max_digits) do
    <<kept::binary-size(^max_digits), dropped::binary>> = digits

    case :binary.match(dropped, @nonzero_digits) do
      :nomatch -> kept
      _found -> kept <> "1"
    end
  end

  defp exponent("", _radix), do: {:ok, 0}
  defp exponent(<<marker, rest::binary>>, :decimal) when marker in [?e, ?E], do: signed_exponent(rest)
  defp exponent(<<marker, rest::binary>>, :hex) when marker in [?p, ?P], do: signed_exponent(rest)
  defp exponent(_exponent_part, _radix), do: :error

  defp signed_exponent(<<?-, digits::binary>>), do: exponent_digits(digits, :negative)
  defp signed_exponent(<<?+, digits::binary>>), do: exponent_digits(digits, :positive)
  defp signed_exponent(digits), do: exponent_digits(digits, :positive)

  defp exponent_digits(<<digit, _::binary>> = digits, sign) when digit in ?0..?9 do
    accumulate_exponent(digits, 0, sign)
  end

  defp exponent_digits(_digits, _sign), do: :error

  defp accumulate_exponent(<<digit, rest::binary>>, exponent, sign) when digit in ?0..?9 do
    accumulate_exponent(rest, min(exponent * 10 + digit - ?0, @exponent_cap), sign)
  end

  defp accumulate_exponent("", exponent, sign), do: {:ok, signed(exponent, sign)}
  defp accumulate_exponent(_rest, _exponent, _sign), do: :error

  defp parse_base_digits("", _base, _sign), do: :error
  defp parse_base_digits(digits, base, sign), do: accumulate_base_digits(digits, base, 0, 0, sign)

  # The value modulo 2^64 is kept as two 32-bit halves, so every step is
  # small-integer arithmetic.
  defp accumulate_base_digits("", _base, high_half, low_half, sign) do
    {:ok, (bsl(high_half, 32) + low_half) |> signed(sign) |> wrap_int64()}
  end

  defp accumulate_base_digits(<<char, rest::binary>>, base, high_half, low_half, sign) do
    case digit_value(char) do
      digit when digit < base ->
        low_half = low_half * base + digit
        high_half = high_half * base + bsr(low_half, 32)
        accumulate_base_digits(rest, base, band(high_half, @uint32_mask), band(low_half, @uint32_mask), sign)

      _not_a_digit_in_base ->
        :error
    end
  end

  defp digit_value(char) when char in ?0..?9, do: char - ?0
  defp digit_value(char) when char in ?a..?z, do: char - ?a + 10
  defp digit_value(char) when char in ?A..?Z, do: char - ?A + 10
  defp digit_value(_char), do: @not_a_digit

  defp take_digits(binary, radix) do
    count = count_digits(binary, radix, 0)
    <<digits::binary-size(^count), rest::binary>> = binary
    {digits, rest}
  end

  defp count_digits(<<digit, rest::binary>>, :decimal, count) when digit in ?0..?9 do
    count_digits(rest, :decimal, count + 1)
  end

  defp count_digits(<<digit, rest::binary>>, :hex, count) when digit in ?0..?9 or digit in ?a..?f or digit in ?A..?F do
    count_digits(rest, :hex, count + 1)
  end

  defp count_digits(_rest, _radix, count), do: count

  defp trim_leading_zeros(<<?0, rest::binary>>), do: trim_leading_zeros(rest)
  defp trim_leading_zeros(digits), do: digits

  defp signed(value, :positive), do: value
  defp signed(value, :negative), do: -value

  defp wrap_int64(value) do
    case band(value, @uint64_mask) do
      wrapped when wrapped >= @sign_bit -> wrapped - @uint64_modulus
      wrapped -> wrapped
    end
  end
end
