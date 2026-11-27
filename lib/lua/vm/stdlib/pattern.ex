defmodule Lua.VM.Stdlib.Pattern do
  @moduledoc """
  Lua 5.3 pattern matching engine.

  Implements Lua's pattern language, which is NOT regex but a simpler custom syntax:
  - Character classes: %a (letters), %d (digits), %l (lowercase), %u (uppercase),
    %w (alphanumeric), %s (whitespace), %p (punctuation), %c (control), . (any)
  - Quantifiers: * (0+ greedy), + (1+ greedy), - (0+ lazy), ? (0 or 1)
  - Anchors: ^ (start), $ (end)
  - Sets: [abc], [^abc], [%a%d]
  - Captures: (pattern), %1-%9 backreferences
  - Balanced: %bxy
  - Escape: % + non-alphanumeric = literal

  Functions taking a VM state charge matcher steps to its `:max_instructions`
  budget. Captures per match and backtracking depth are capped as in PUC-Lua.
  """

  import Bitwise

  alias Lua.VM.Limits
  alias Lua.VM.RuntimeError
  alias Lua.VM.State
  alias Lua.VM.Stdlib.Util

  # A matcher step and a byte of the result are each one unit of work.
  @steps_per_instruction Limits.work_per_instruction()
  # PUC-Lua's MAXCCALLS and LUA_MAXCAPTURES.
  @max_match_depth 200
  @max_captures 32

  # Largest 64-bit small integer: never runs out, never allocates.
  @unbounded_fuel 0x07FF_FFFF_FFFF_FFFF

  defguardp is_fuel_left(result) when is_integer(result) and result >= 0

  @doc """
  Find first match of pattern in subject starting at position `init` (1-based).
  Returns `{start, stop, captures}` or `:nomatch`.
  """
  def find(subject, pattern, init \\ 1) do
    {result, _state} = find(subject, pattern, init, %State{})
    result
  end

  @doc """
  Like `find/3`, charging the matcher's steps to `state`. Returns `{result, state}`.
  """
  def find(subject, pattern, init, %State{} = state) do
    {result, fuel} = find_fueled(subject, pattern, init, available_fuel(state))
    {result, settle!(fuel, state)}
  end

  defp find_fueled(subject, pattern, init, fuel) do
    len = byte_size(subject)

    case normalize_init(init, len) do
      :out_of_range ->
        {:nomatch, fuel}

      # One step per pattern byte, charged before compiling.
      start_pos when fuel >= byte_size(pattern) ->
        {anchored, pattern_elems} = compile(pattern)
        last_start = if anchored, do: start_pos, else: len
        find_from(subject, start_pos, last_start, pattern_elems, fuel - byte_size(pattern))

      _start_pos ->
        {:nomatch, fuel - byte_size(pattern)}
    end
  end

  # Per Lua 5.3 §6.4, init follows the same indexing rules as string.sub:
  # negative values count from the end; out-of-range low values clamp to 1.
  # A positive init beyond `len + 1` yields no match — even the empty
  # pattern doesn't match past that point.
  defp normalize_init(init, len) when init > len + 1, do: :out_of_range
  defp normalize_init(init, _len) when init > 0, do: init - 1
  defp normalize_init(init, len) when init < 0, do: max(len + init, 0)
  defp normalize_init(_init, _len), do: 0

  defp find_from(_subject, pos, last_start, _pattern, fuel) when pos > last_start, do: {:nomatch, fuel}

  defp find_from(subject, pos, last_start, pattern, fuel) do
    case match_pattern(subject, pos, pattern, fuel) do
      {:match, end_pos, captures, fuel} -> {{pos + 1, end_pos, captures}, fuel}
      fuel when is_fuel_left(fuel) -> find_from(subject, pos + 1, last_start, pattern, fuel)
      stop -> {:nomatch, stop}
    end
  end

  @doc """
  Match pattern against subject, returning captures or :nomatch.
  """
  def match(subject, pattern, init \\ 1) do
    subject |> find(pattern, init) |> to_match(subject)
  end

  @doc """
  Like `match/3`, charging the matcher's steps to `state`. Returns `{result, state}`.
  """
  def match(subject, pattern, init, %State{} = state) do
    {found, state} = find(subject, pattern, init, state)
    {to_match(found, subject), state}
  end

  defp to_match({_start, _stop, captures}, _subject) when captures != [], do: {:match, captures}
  defp to_match({start, stop, []}, subject), do: {:match, [binary_part(subject, start - 1, stop - start + 1)]}
  defp to_match(:nomatch, _subject), do: :nomatch

  @doc """
  Global match - returns the list of every match's captures (or whole match).
  """
  def gmatch(subject, pattern) do
    {iterator, state} = gmatch_start(pattern, %State{})
    gmatch_all(subject, iterator, state, [])
  end

  defp gmatch_all(subject, iterator, state, matches) do
    case gmatch_next(subject, iterator, state) do
      {nil, _iterator, _state} -> Enum.reverse(matches)
      {result, iterator, state} -> gmatch_all(subject, iterator, state, [result | matches])
    end
  end

  @doc """
  Compiles `pattern` into an opaque iterator for `gmatch_next/3`, charging
  the compile to `state`. Returns `{iterator, state}`.
  """
  def gmatch_start(pattern, %State{} = state) do
    state = settle!(available_fuel(state) - byte_size(pattern), state)
    {{gmatch_elements(pattern), 0, -1}, state}
  end

  @doc """
  Advances a `gmatch_start/2` iterator to the next match in `subject`,
  charging the steps to `state`. Returns `{captures, iterator, state}`, with
  `nil` captures once the subject is exhausted.
  """
  def gmatch_next(subject, {pattern_elems, pos, lastmatch}, %State{} = state) do
    len = byte_size(subject)

    case gmatch_step(subject, pos, len, pattern_elems, lastmatch, available_fuel(state)) do
      {:match, result, next_pos, end_pos, fuel} ->
        {result, {pattern_elems, next_pos, end_pos}, settle!(fuel, state)}

      # Parked past the end, so further calls return at once.
      {:done, fuel} ->
        {nil, {pattern_elems, len + 1, lastmatch}, settle!(fuel, state)}
    end
  end

  # Lua 5.3 §6.4 (`string.gmatch`): a leading `^` does not work as an anchor
  # (it would prevent the iteration). PUC-Lua's gmatch_aux never strips
  # it, so `match` sees it as an ordinary character — recompile the
  # pattern with the caret kept as a literal.
  defp gmatch_elements(pattern) do
    case compile(pattern) do
      {false, elems} -> elems
      {true, _elems} -> compile_elements(pattern, [])
    end
  end

  defp gmatch_step(_subject, pos, len, _pattern, _lastmatch, fuel) when pos > len, do: {:done, fuel}

  # PUC Lua's `gmatch_aux` skips a match whose end equals the previous match's
  # end — this prevents an empty match that fires immediately after a previous
  # non-empty match from being returned twice (once at the boundary, once on
  # the empty-advance step).
  defp gmatch_step(subject, pos, len, pattern, lastmatch, fuel) do
    case match_pattern(subject, pos, pattern, fuel) do
      {:match, end_pos, _, fuel} when end_pos == lastmatch ->
        # Same end as previous match — skip and try at next position.
        gmatch_step(subject, pos + 1, len, pattern, lastmatch, fuel)

      {:match, end_pos, captures, fuel} ->
        result =
          if captures == [] do
            [binary_part(subject, pos, max(end_pos - pos, 0))]
          else
            captures
          end

        # Advance at least 1 to prevent infinite loop on empty match
        next_pos = if end_pos == pos, do: pos + 1, else: end_pos
        {:match, result, next_pos, end_pos, fuel}

      fuel when is_fuel_left(fuel) ->
        gmatch_step(subject, pos + 1, len, pattern, lastmatch, fuel)

      stop ->
        {:done, stop}
    end
  end

  @doc """
  Global substitution. Returns `{result_string, count}`.

  `repl` is one of: binary (string), function (arity 1, `args -> result`), or
  any other term (treated as a no-op, returning the whole match).

  This entry point does NOT thread Lua VM state through the function
  replacement — any side effects in the callback (upvalue mutation, table
  writes) are dropped on the floor. For Lua-level `string.gsub` use
  `gsub_stateful/5` instead.
  """
  def gsub(subject, pattern, repl, max_n \\ nil) do
    stateful_repl =
      if is_function(repl, 1) do
        fn args, state -> {repl.(args), state} end
      else
        repl
      end

    {result, count, _state} = gsub_stateful(subject, pattern, stateful_repl, nil, max_n)

    {result, count}
  end

  @doc """
  Stateful global substitution. Returns `{result_string, count, state}`.

  When `repl` is a function it must have arity 2 — `(args, state) -> {result, state}`
  — so callbacks that mutate Lua state (upvalues, tables) thread their
  changes back out. String and table replacements are state-pass-through.

  The matcher and a function replacement charge the same instruction budget.
  """
  def gsub_stateful(subject, pattern, repl, state, max_n \\ nil) do
    case available_fuel(state) - byte_size(pattern) do
      fuel when is_fuel_left(fuel) ->
        {anchored, pattern_elems} = compile(pattern)
        {result, count, state, fuel} = do_gsub(subject, anchored, pattern_elems, repl, max_n, state, fuel)
        {result, count, settle!(fuel, state)}

      overdrawn ->
        settle!(overdrawn, state)
    end
  end

  # A `^`-anchored pattern matches only at the start of the subject
  # (Lua 5.3 §6.4.1), so gsub performs at most one replacement there and
  # keeps the remainder untouched — PUC-Lua str_gsub's `anchor` flag makes
  # its scan loop run exactly once. An unanchored pattern scans every
  # position via gsub_from/12.

  defp do_gsub(subject, true, _pattern, _repl, max_n, state, fuel) when max_n != nil and max_n <= 0 do
    {subject, 0, state, fuel}
  end

  defp do_gsub(subject, true, pattern, repl, _max_n, state, fuel) do
    case match_pattern(subject, 0, pattern, fuel) do
      {:match, end_pos, captures, fuel} ->
        whole_match = binary_part(subject, 0, end_pos)
        {replacement, state, fuel} = apply_replacement(repl, whole_match, captures, 0, state, fuel)
        rest = binary_part(subject, end_pos, byte_size(subject) - end_pos)
        finish_gsub([replacement], rest, byte_size(replacement), 1, state, fuel)

      fuel ->
        {subject, 0, state, fuel}
    end
  end

  defp do_gsub(subject, false, pattern, repl, max_n, state, fuel) do
    gsub_from(subject, 0, byte_size(subject), pattern, repl, max_n, 0, [], 0, state, false, fuel)
  end

  # Lua 5.3.3+ semantics: an empty match that starts where the *previous*
  # match ended (with the previous match itself being empty-and-skipped, or
  # immediately following any prior match) does not replace — we advance by
  # one byte instead. Without this, ` *` against `a b cd` double-fires at
  # every space boundary and produces `-a--b--c-d-` instead of `-a-b-c-d-`.
  #
  # The flag `skip_empty?` is set after every matched-and-applied replacement;
  # the next iteration is allowed to fire an empty match only after we've
  # advanced past that boundary.
  #
  # `size` is the byte count accumulated in `acc`. Replacements can grow the
  # result without bound relative to the subject, so it is checked against
  # the string ceiling as each one is produced (see apply_replacement/6) and
  # once more, with the unmatched remainder, before the result is built.
  #
  # A stop value raises here with the latest `state`, keeping the heap
  # effects of earlier replacement callbacks.

  defp gsub_from(subject, pos, len, _pattern, _repl, max_n, count, acc, size, state, _skip_empty?, fuel)
       when pos > len or (max_n != nil and count >= max_n) do
    # Append remaining subject (clamp pos so we never read past end_of_string)
    remaining =
      if pos < len, do: binary_part(subject, pos, len - pos), else: ""

    finish_gsub(acc, remaining, size, count, state, fuel)
  end

  defp gsub_from(subject, pos, len, pattern, repl, max_n, count, acc, size, state, skip_empty?, fuel) do
    case match_pattern(subject, pos, pattern, fuel) do
      {:match, end_pos, _captures, fuel} when skip_empty? and end_pos == pos ->
        # Empty match immediately after a previous match — skip without
        # replacing, advance by one byte (or terminate at end of subject).
        if pos < len do
          char = <<:binary.at(subject, pos)>>
          gsub_from(subject, pos + 1, len, pattern, repl, max_n, count, [char | acc], size + 1, state, false, fuel)
        else
          finish_gsub(acc, "", size, count, state, fuel)
        end

      {:match, end_pos, captures, fuel} ->
        if max_n != nil and count >= max_n do
          remaining = binary_part(subject, pos, len - pos)
          finish_gsub(acc, remaining, size, count, state, fuel)
        else
          whole_match = binary_part(subject, pos, max(end_pos - pos, 0))
          {replacement, state, fuel} = apply_replacement(repl, whole_match, captures, size, state, fuel)
          empty_match? = end_pos == pos
          next_pos = if empty_match?, do: pos + 1, else: end_pos
          prefix = if empty_match? and pos < len, do: <<:binary.at(subject, pos)>>, else: ""

          # Only flag skip on the next iteration if THIS match was non-empty
          # — the skip-empty rule guards against an empty match that fires
          # immediately on the boundary of a prior non-empty match (see
          # Lua 5.3.3 changelog). Empty matches that already advanced via
          # `prefix` don't trigger the guard.
          gsub_from(
            subject,
            next_pos,
            len,
            pattern,
            repl,
            max_n,
            count + 1,
            [prefix, replacement | acc],
            size + byte_size(replacement) + byte_size(prefix),
            state,
            not empty_match?,
            fuel
          )
        end

      fuel when is_fuel_left(fuel) ->
        if pos < len do
          char = <<:binary.at(subject, pos)>>
          gsub_from(subject, pos + 1, len, pattern, repl, max_n, count, [char | acc], size + 1, state, false, fuel)
        else
          finish_gsub(acc, "", size, count, state, fuel)
        end

      stop ->
        settle!(stop, state)
    end
  end

  defp finish_gsub(acc, remaining, size, count, state, fuel) do
    result_size = size + byte_size(remaining)
    check_result_size!(result_size, state)

    case fuel - result_size do
      fuel when is_fuel_left(fuel) -> {IO.iodata_to_binary([Enum.reverse(acc), remaining]), count, state, fuel}
      overdrawn -> settle!(overdrawn, state)
    end
  end

  # The non-stateful `gsub/4` entry calls with `state == nil` and falls back
  # to the default ceiling.
  defp check_result_size!(size, %State{max_string_bytes: max}) when size <= max, do: :ok

  defp check_result_size!(size, %State{max_string_bytes: max} = state) do
    Limits.check_string_size!(size, max, state)
  end

  defp check_result_size!(size, nil), do: Limits.check_string_size!(size)

  # Produces the replacement for one match, refusing it when it would take
  # the result — `size` bytes so far — past the string ceiling.
  defp apply_replacement(repl, whole_match, captures, size, state, fuel) when is_binary(repl) do
    # Replace %0 with whole match, %1-%9 with captures. A replacement with
    # no `%` comes back as the same binary; otherwise the expansion is
    # iodata, sized and checked before it is flattened.
    case replace_captures(repl, whole_match, captures) do
      literal when is_binary(literal) ->
        check_result_size!(size + byte_size(literal), state)
        {literal, state, fuel}

      expansion ->
        check_result_size!(size + IO.iodata_length(expansion), state)
        {IO.iodata_to_binary(expansion), state, fuel}
    end
  end

  # A callback runs Lua on the same tally: lend it the fuel, take back the rest.
  defp apply_replacement(repl, whole_match, captures, size, state, fuel) when is_function(repl, 2) do
    args = if captures == [], do: [whole_match], else: captures
    {result, state} = repl.(args, store_fuel(state, fuel))

    replacement =
      case result do
        result when is_binary(result) -> result
        result when is_number(result) -> to_string(result)
        false -> whole_match
        nil -> whole_match
        other -> raise_invalid_replacement(other, state)
      end

    check_result_size!(size + byte_size(replacement), state)
    {replacement, state, fuel_after_callback(state, fuel)}
  end

  defp apply_replacement(_repl, whole_match, _captures, size, state, fuel) do
    check_result_size!(size + byte_size(whole_match), state)
    {whole_match, state, fuel}
  end

  # The callback may have made heap mutations (global/table/upvalue/metatable
  # writes) that thread back through `state` before returning an invalid value.
  # Ferry the freshest `state` out on the raise so a protected unwind keeps
  # those effects (Lua 5.3 §2.3). The non-stateful `gsub/4` entry calls with
  # `state == nil`, so only attach when a real `%State{}` is in scope.
  defp raise_invalid_replacement(other, %State{} = state) do
    raise RuntimeError, value: "invalid replacement value (a #{Util.typeof(other)})", state: state
  end

  defp raise_invalid_replacement(other, _state) do
    raise RuntimeError, value: "invalid replacement value (a #{Util.typeof(other)})"
  end

  # Builds iodata rather than a binary: literal runs and captures are
  # referenced, not copied, so a replacement that repeats `%0` many times
  # stays the size of the replacement string until its expanded size has
  # been checked. A replacement with no `%` comes back as-is.
  defp replace_captures(repl, whole, captures), do: literal_run(repl, repl, 0, whole, captures)

  # Scans to the next `%`; the `len` bytes of `run` before it are one piece.
  defp literal_run(<<?%, rest::binary>>, run, len, whole, captures) do
    [binary_part(run, 0, len), replace_directive(rest, whole, captures)]
  end

  defp literal_run(<<_byte, rest::binary>>, run, len, whole, captures) do
    literal_run(rest, run, len + 1, whole, captures)
  end

  defp literal_run(<<>>, run, _len, _whole, _captures), do: run

  defp replace_directive(<<c, rest::binary>>, whole, captures) when c in ?0..?9 do
    idx = c - ?0

    value =
      cond do
        idx == 0 ->
          whole

        # When the pattern has no explicit captures, %1 refers to the
        # whole match (PUC-Lua compatibility). Any higher index with no
        # captures, or any index past the number of captures, is invalid.
        idx <= length(captures) ->
          Enum.at(captures, idx - 1)

        idx == 1 ->
          whole

        true ->
          raise RuntimeError, value: "invalid capture index %#{idx} in replacement string"
      end

    [capture_to_binary(value), replace_captures(rest, whole, captures)]
  end

  defp replace_directive("%" <> rest, whole, captures) do
    ["%", replace_captures(rest, whole, captures)]
  end

  defp replace_directive(_other, _whole, _captures) do
    raise RuntimeError, value: "invalid use of '%' in replacement string"
  end

  # Captures from `()` (position captures) are integers; everything else is
  # already a binary. Coerce to a binary so iodata-flattening downstream
  # doesn't reinterpret integers as raw bytes.
  defp capture_to_binary(value) when is_binary(value), do: value
  defp capture_to_binary(value) when is_integer(value), do: Integer.to_string(value)
  defp capture_to_binary(value), do: to_string(value)

  # --- Pattern Compiler ---

  @doc """
  Compile a pattern string into a list of pattern elements.
  Returns `{anchored, elements}`.
  """
  def compile(pattern) do
    {anchored, rest} =
      case pattern do
        "^" <> rest -> {true, rest}
        _ -> {false, pattern}
      end

    elements = compile_elements(rest, [])
    {anchored, elements}
  end

  defp compile_elements("", acc), do: Enum.reverse(acc)

  defp compile_elements("$", acc) do
    Enum.reverse([:anchor_end | acc])
  end

  defp compile_elements("()" <> rest, acc) do
    # Position capture: records the current byte position (1-based) at this point.
    compile_elements(rest, [:position_capture | acc])
  end

  defp compile_elements("(" <> rest, acc) do
    compile_elements(rest, [:capture_start | acc])
  end

  defp compile_elements(")" <> rest, acc) do
    compile_elements(rest, [:capture_end | acc])
  end

  defp compile_elements(pattern, acc) do
    {elem, rest} = compile_one_element(pattern)

    # Check for quantifier
    case rest do
      "*" <> rest2 -> compile_elements(rest2, [{:greedy_star, elem} | acc])
      "+" <> rest2 -> compile_elements(rest2, [{:greedy_plus, elem} | acc])
      "-" <> rest2 -> compile_elements(rest2, [{:lazy_star, elem} | acc])
      "?" <> rest2 -> compile_elements(rest2, [{:optional, elem} | acc])
      _ -> compile_elements(rest, [elem | acc])
    end
  end

  defp compile_one_element("." <> rest), do: {:any, rest}

  defp compile_one_element("%" <> <<c, rest::binary>>) do
    cond do
      c == ?b ->
        # Balanced match %bxy
        <<x, y, rest2::binary>> = rest
        {{:balanced, x, y}, rest2}

      c in ?1..?9 ->
        {{:backref, c - ?0}, rest}

      true ->
        {{:class, c}, rest}
    end
  end

  defp compile_one_element("[" <> rest) do
    {negated, rest} =
      case rest do
        "^" <> r -> {true, r}
        _ -> {false, rest}
      end

    {set_elements, rest} = compile_set(rest, [])
    {bitmap, classes} = set_membership(set_elements)
    {{:set, negated, bitmap, classes}, rest}
  end

  defp compile_one_element(<<c, rest::binary>>) do
    {{:literal, c}, rest}
  end

  # Letters `match_char_class/2` treats as classes; `%` before any other byte
  # is that byte.
  @class_letters ~c"aAcCdDgGlLpPsSuUwWxXzZ"

  # A 256-bit membership bitmap plus the distinct classes, so a set test does
  # not grow with the number of items.
  defp set_membership(elements) do
    {mask, classes} =
      Enum.reduce(elements, {0, []}, fn
        {:literal, c}, {mask, classes} ->
          {mask ||| 1 <<< c, classes}

        {:range, lo, hi}, {mask, classes} when lo <= hi ->
          {mask ||| ((1 <<< (hi - lo + 1)) - 1) <<< lo, classes}

        {:range, _lo, _hi}, membership ->
          membership

        {:class, c}, {mask, classes} when c in @class_letters ->
          if c in classes, do: {mask, classes}, else: {mask, [c | classes]}

        {:class, c}, {mask, classes} ->
          {mask ||| 1 <<< c, classes}
      end)

    {<<mask::little-size(256)>>, classes}
  end

  defp compile_set("]" <> rest, acc) when acc != [] do
    {Enum.reverse(acc), rest}
  end

  defp compile_set("%" <> <<c, rest::binary>>, acc) do
    compile_set(rest, [{:class, c} | acc])
  end

  defp compile_set(<<c1, "-", c2, rest::binary>>, acc) when c2 != ?] do
    compile_set(rest, [{:range, c1, c2} | acc])
  end

  defp compile_set(<<c, rest::binary>>, acc) do
    compile_set(rest, [{:literal, c} | acc])
  end

  # --- Pattern Matcher ---

  # Match a compiled pattern against subject starting at pos.
  #
  # Returns `{:match, end_pos, captures, fuel}`, or the fuel on failure: a
  # non-negative fuel is no match; a negative one (budget spent) or a binary
  # (structural limit) is a stop value callers return untouched. Each call
  # costs one step; backtracking calls also spend one level of `depth`.
  #
  # Capture model:
  #   `captures` is a list in OPENING order. Each entry is `{:open, start_pos}`
  #   while a capture is in-flight, or `{:done, value}` once closed. Position
  #   captures are appended directly as `{:done, pos+1}`.
  #
  #   `cstack` is a stack of indices into `captures`, pointing at the most
  #   recently-opened-but-not-yet-closed entry. LIFO — `capture_end` always
  #   closes the innermost open capture.
  #
  # This preserves the Lua-required ordering (captures numbered by opening
  # position) even for nested groups like `(((.).).* (%w*))`.
  defp match_pattern(subject, pos, pattern, fuel) do
    match_elements(subject, pos, pattern, [], [], fuel - 1, @max_match_depth)
  end

  defp match_elements(_subject, _pos, _pattern, _cstack, _captures, fuel, _depth) when fuel < 0, do: fuel

  defp match_elements(_subject, _pos, _pattern, _cstack, _captures, _fuel, 0), do: "pattern too complex"

  # All pattern elements consumed — success
  defp match_elements(_subject, pos, [], _cstack, captures, fuel, _depth) do
    {:match, pos, finalize_captures(captures), fuel}
  end

  # Anchor end — must be at end of string
  defp match_elements(subject, pos, [:anchor_end | rest], cstack, captures, fuel, depth) do
    if pos == byte_size(subject) do
      match_elements(subject, pos, rest, cstack, captures, fuel - 1, depth)
    else
      fuel
    end
  end

  defp match_elements(_subject, _pos, [:capture_start | _rest], _cstack, captures, _fuel, _depth)
       when length(captures) >= @max_captures, do: "too many captures"

  defp match_elements(_subject, _pos, [:position_capture | _rest], _cstack, captures, _fuel, _depth)
       when length(captures) >= @max_captures, do: "too many captures"

  # Capture start — append open marker, remember its index on the stack
  defp match_elements(subject, pos, [:capture_start | rest], cstack, captures, fuel, depth) do
    index = length(captures)
    match_elements(subject, pos, rest, [index | cstack], captures ++ [{:open, pos}], fuel - 1, depth)
  end

  # Position capture — record the current 1-based byte position as a number
  defp match_elements(subject, pos, [:position_capture | rest], cstack, captures, fuel, depth) do
    match_elements(subject, pos, rest, cstack, captures ++ [{:done, pos + 1}], fuel - 1, depth)
  end

  # Capture end — replace the topmost open marker with its captured value
  defp match_elements(subject, pos, [:capture_end | rest], [index | cstack], captures, fuel, depth) do
    {:open, start} = Enum.at(captures, index)
    captured = binary_part(subject, start, pos - start)
    captures = List.replace_at(captures, index, {:done, captured})
    match_elements(subject, pos, rest, cstack, captures, fuel - 1, depth)
  end

  # Greedy star (0 or more, greedy). One step per byte scanned.
  defp match_elements(subject, pos, [{:greedy_star, elem} | rest], cstack, captures, fuel, depth) do
    # Find max consecutive matches
    max_pos = greedy_count(subject, pos, elem)
    # Try from max down to 0
    backtrack_greedy(subject, pos, max_pos, rest, cstack, captures, fuel - (max_pos - pos), depth)
  end

  # Greedy plus (1 or more, greedy)
  defp match_elements(subject, pos, [{:greedy_plus, elem} | rest], cstack, captures, fuel, depth) do
    if match_class(subject, pos, elem) do
      max_pos = greedy_count(subject, pos, elem)
      backtrack_greedy(subject, pos + 1, max_pos, rest, cstack, captures, fuel - (max_pos - pos), depth)
    else
      fuel
    end
  end

  # Lazy star (0 or more, lazy)
  defp match_elements(subject, pos, [{:lazy_star, elem} | rest], cstack, captures, fuel, depth) do
    lazy_match(subject, pos, elem, rest, cstack, captures, fuel, depth)
  end

  # Optional (0 or 1)
  defp match_elements(subject, pos, [{:optional, elem} | rest], cstack, captures, fuel, depth) do
    # Try with 1 match first
    if match_class(subject, pos, elem) do
      case match_elements(subject, pos + 1, rest, cstack, captures, fuel - 1, depth - 1) do
        fuel when is_fuel_left(fuel) -> match_elements(subject, pos, rest, cstack, captures, fuel - 1, depth)
        result -> result
      end
    else
      match_elements(subject, pos, rest, cstack, captures, fuel - 1, depth)
    end
  end

  # Backref — references a previously-closed capture by 1-based index.
  # Open captures and out-of-range references fail to match. One step per
  # byte compared.
  defp match_elements(subject, pos, [{:backref, n} | rest], cstack, captures, fuel, depth) do
    case Enum.at(captures, n - 1) do
      {:done, captured} when is_binary(captured) ->
        cap_len = byte_size(captured)

        if pos + cap_len <= byte_size(subject) and
             binary_part(subject, pos, cap_len) == captured do
          match_elements(subject, pos + cap_len, rest, cstack, captures, fuel - 1 - cap_len, depth)
        else
          fuel - cap_len
        end

      _ ->
        fuel
    end
  end

  # Balanced match %bxy. One step per byte scanned.
  defp match_elements(subject, pos, [{:balanced, open, close} | rest], cstack, captures, fuel, depth) do
    case match_balanced(subject, pos, open, close) do
      {:ok, end_pos} -> match_elements(subject, end_pos, rest, cstack, captures, fuel - 1 - (end_pos - pos), depth)
      {:nomatch, scan_end} -> fuel - (scan_end - pos)
    end
  end

  # Single element match
  defp match_elements(subject, pos, [elem | rest], cstack, captures, fuel, depth) do
    if match_class(subject, pos, elem) do
      match_elements(subject, pos + 1, rest, cstack, captures, fuel - 1, depth)
    else
      fuel
    end
  end

  # Greedy backtracking: try longest match first
  defp backtrack_greedy(_subject, min_pos, pos, _rest, _cstack, _captures, fuel, _depth) when pos < min_pos do
    fuel
  end

  defp backtrack_greedy(subject, min_pos, pos, rest, cstack, captures, fuel, depth) do
    case match_elements(subject, pos, rest, cstack, captures, fuel - 1, depth - 1) do
      fuel when is_fuel_left(fuel) ->
        backtrack_greedy(subject, min_pos, pos - 1, rest, cstack, captures, fuel, depth)

      result ->
        result
    end
  end

  # Lazy matching: try shortest match first
  defp lazy_match(subject, pos, elem, rest, cstack, captures, fuel, depth) do
    # Try matching 0 characters first
    case match_elements(subject, pos, rest, cstack, captures, fuel - 1, depth - 1) do
      fuel when is_fuel_left(fuel) ->
        # Try consuming one more character
        if match_class(subject, pos, elem) do
          lazy_match(subject, pos + 1, elem, rest, cstack, captures, fuel, depth)
        else
          fuel
        end

      result ->
        result
    end
  end

  # Count max greedy matches from pos
  defp greedy_count(subject, pos, elem) do
    if match_class(subject, pos, elem) do
      greedy_count(subject, pos + 1, elem)
    else
      pos
    end
  end

  # Match balanced %bxy. Returns `{:ok, end_pos}` or `{:nomatch, scan_end}`.
  defp match_balanced(subject, pos, open, close) do
    len = byte_size(subject)

    if pos >= len or :binary.at(subject, pos) != open do
      {:nomatch, pos}
    else
      match_balanced_inner(subject, pos + 1, len, open, close, 1)
    end
  end

  defp match_balanced_inner(_subject, pos, len, _open, _close, _depth) when pos >= len, do: {:nomatch, len}

  defp match_balanced_inner(subject, pos, len, open, close, depth) do
    c = :binary.at(subject, pos)

    cond do
      c == close and depth == 1 -> {:ok, pos + 1}
      c == close -> match_balanced_inner(subject, pos + 1, len, open, close, depth - 1)
      c == open -> match_balanced_inner(subject, pos + 1, len, open, close, depth + 1)
      true -> match_balanced_inner(subject, pos + 1, len, open, close, depth)
    end
  end

  # Match a single character class at position
  defp match_class(_subject, pos, _elem) when pos < 0, do: false

  defp match_class(subject, pos, _elem) when pos >= byte_size(subject), do: false

  defp match_class(subject, pos, :any) do
    pos < byte_size(subject)
  end

  defp match_class(subject, pos, {:literal, c}) do
    :binary.at(subject, pos) == c
  end

  defp match_class(subject, pos, {:class, c}) do
    ch = :binary.at(subject, pos)
    match_char_class(ch, c)
  end

  defp match_class(subject, pos, {:set, negated, bitmap, classes}) do
    ch = :binary.at(subject, pos)
    matched = (:binary.at(bitmap, ch >>> 3) >>> (ch &&& 7) &&& 1) == 1 or in_classes?(ch, classes)
    matched != negated
  end

  defp in_classes?(_ch, []), do: false
  defp in_classes?(ch, [c | rest]), do: match_char_class(ch, c) or in_classes?(ch, rest)

  # Character class matchers
  defp match_char_class(ch, ?a), do: ch in ?a..?z or ch in ?A..?Z
  defp match_char_class(ch, ?A), do: not (ch in ?a..?z or ch in ?A..?Z)
  defp match_char_class(ch, ?d), do: ch in ?0..?9
  defp match_char_class(ch, ?D), do: ch not in ?0..?9
  defp match_char_class(ch, ?l), do: ch in ?a..?z
  defp match_char_class(ch, ?L), do: ch not in ?a..?z
  defp match_char_class(ch, ?u), do: ch in ?A..?Z
  defp match_char_class(ch, ?U), do: ch not in ?A..?Z
  defp match_char_class(ch, ?w), do: ch in ?a..?z or ch in ?A..?Z or ch in ?0..?9
  defp match_char_class(ch, ?W), do: not (ch in ?a..?z or ch in ?A..?Z or ch in ?0..?9)

  defp match_char_class(ch, ?s), do: ch in [?\s, ?\t, ?\n, ?\r, ?\v, 0x0C]

  defp match_char_class(ch, ?S), do: ch not in [?\s, ?\t, ?\n, ?\r, ?\v, 0x0C]

  defp match_char_class(ch, ?p) do
    ch in ?!..?/ or ch in ?:..?@ or ch in ?[..?` or ch in ?{..?~
  end

  defp match_char_class(ch, ?P) do
    not (ch in ?!..?/ or ch in ?:..?@ or ch in ?[..?` or ch in ?{..?~)
  end

  defp match_char_class(ch, ?c), do: ch < 32 or ch == 127
  defp match_char_class(ch, ?C), do: not (ch < 32 or ch == 127)

  # %g — printable characters except space (ASCII 0x21..0x7E)
  defp match_char_class(ch, ?g), do: ch in 0x21..0x7E
  defp match_char_class(ch, ?G), do: ch not in 0x21..0x7E

  # %x — hexadecimal digit
  defp match_char_class(ch, ?x), do: ch in ?0..?9 or ch in ?a..?f or ch in ?A..?F
  defp match_char_class(ch, ?X), do: not (ch in ?0..?9 or ch in ?a..?f or ch in ?A..?F)

  # %z — the byte with value 0 (deprecated in 5.2+, present in 5.3 reference);
  # %Z — its complement.
  defp match_char_class(ch, ?z), do: ch == 0
  defp match_char_class(ch, ?Z), do: ch != 0

  # Escaped literal (non-alphanumeric after %)
  defp match_char_class(ch, literal), do: ch == literal

  # Strip the {:done, value} wrappers in opening order. Any remaining
  # {:open, _} entries indicate an unclosed capture, which is a pattern
  # validity issue — fail closed by returning [].
  defp finalize_captures(captures) do
    captures
    |> Enum.reduce_while([], fn
      {:done, value}, acc -> {:cont, [value | acc]}
      {:open, _}, _acc -> {:halt, :unclosed}
    end)
    |> case do
      :unclosed -> []
      acc -> Enum.reverse(acc)
    end
  end

  # --- Step budget ---
  #
  # Fuel is the steps left before the tally reaches `max_instructions`, so it
  # alone determines the tally to charge back.

  defp available_fuel(%State{max_instructions: max, instruction_count: tally}) when is_integer(max) do
    (max - 1 - tally) * @steps_per_instruction
  end

  defp available_fuel(_state), do: @unbounded_fuel

  defp store_fuel(%State{max_instructions: max} = state, fuel) when is_integer(max) do
    %{state | instruction_count: max - 1 - div(fuel, @steps_per_instruction)}
  end

  defp store_fuel(state, _fuel), do: state

  # `store_fuel/2` kept whole instructions only; the lent remainder comes back.
  defp fuel_after_callback(%State{max_instructions: max} = state, lent_fuel) when is_integer(max) do
    available_fuel(state) + rem(lent_fuel, @steps_per_instruction)
  end

  defp fuel_after_callback(_state, lent_fuel), do: lent_fuel

  # Charges what is left, or raises with `state` so `pcall` keeps heap effects.
  defp settle!(fuel, state) when is_fuel_left(fuel), do: store_fuel(state, fuel)

  # Ticking past the last allowed instruction raises the budget error.
  defp settle!(fuel, %State{max_instructions: max} = state) when is_integer(fuel), do: State.tick!(state, max - 1)

  defp settle!(message, state) when is_binary(message) do
    raise RuntimeError, value: message, state: state
  end
end
