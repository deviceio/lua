defmodule Lua.SuspendResumeTest do
  @moduledoc """
  Host-driven suspension and resumption of a Lua evaluation.

  A `deflua` / Elixir callback suspends the running machine by returning
  `{:suspend, values}` (or `{:suspend, values, lua}` to thread state).
  `Lua.eval!/2` / `Lua.call_function/3` then return `{:suspended, values,
  lua}` with a continuation on the `%Lua{}`, and `Lua.resume/3` re-enters
  the parked machine — the resume values become the suspended call's
  results inside Lua.

  A suspend that cannot be resumed — across a `pcall` boundary, an
  operator metamethod, an `__index` / `__newindex` / `__call` /
  `__tostring` function, a `table.sort` comparator, a `string.gsub`
  replacement function, a generic-for iterator, a `load` reader, a
  `require` loader, or a re-entrant native call — surfaces as the
  catchable Lua error `"attempt to suspend across a native call
  boundary"`.
  """
  use ExUnit.Case, async: true

  alias Lua.VM.Continuation
  alias Lua.VM.Display.Table

  defmodule Scheduler do
    @moduledoc false
    use Lua.API, scope: "sched"

    deflua(yield(value), do: {:suspend, [value]})

    deflua yield_with_state(value), state do
      # Heap effect threaded through the returned %Lua{} before suspending
      {:suspend, [value], Lua.set!(state, [:yielded], value)}
    end

    deflua run(f), state do
      # Re-entrant: calling a Lua closure that suspends from inside a
      # deflua is a native call boundary.
      Lua.call_function!(state, f, [])
    end
  end

  @boundary_message "attempt to suspend across a native call boundary"

  defp yielder(lua) do
    Lua.set!(lua, [:yield], fn args, lua -> {:suspend, args, lua} end)
  end

  describe "eval!/2 suspension" do
    test "a suspending callback parks the evaluation instead of raising" do
      lua = yielder(Lua.new())

      assert {:suspended, [1, 2], lua} = Lua.eval!(lua, "return yield(1, 2)")
      assert %Continuation{} = lua.continuation
    end

    test "resume values become the suspended call's results" do
      lua = yielder(Lua.new())
      {:suspended, [1], lua} = Lua.eval!(lua, "local a = yield(1) return a + 41")

      assert {:ok, [42], lua} = Lua.resume(lua, [1])
      assert lua.continuation == nil
    end

    test "suspend values are decoded like results with decode: true" do
      lua = yielder(Lua.new())

      assert {:suspended, [[{"k", "v"}]], _lua} =
               Lua.eval!(lua, "return yield({k = 'v'})")
    end

    test "suspend values stay encoded with decode: false" do
      lua = yielder(Lua.new())

      assert {:suspended, [%Table{}], _lua} =
               Lua.eval!(lua, "return yield({k = 'v'})", decode: false)
    end

    test "a non-encoded suspend value is rejected like a bad return" do
      lua = Lua.set!(Lua.new(), [:yield], fn _args, _lua -> {:suspend, [%{not: :encoded}]} end)

      assert_raise Lua.RuntimeException,
                   ~r/deflua functions must return encoded data/,
                   fn -> Lua.eval!(lua, "return yield()") end
    end

    test "suspend without threading state keeps the entry state" do
      lua = Lua.set!(Lua.new(), [:yield], fn args -> {:suspend, args} end)
      {:suspended, [], lua} = Lua.eval!(lua, "g = 1 local a = yield() return a")

      assert {:ok, [nil], _lua} = Lua.resume(lua, [])
    end
  end

  describe "result placements" do
    test "multi-return assignment" do
      lua = yielder(Lua.new())
      {:suspended, _, lua} = Lua.eval!(lua, "local a, b = yield() return a * 10 + b")

      assert {:ok, [12], _} = Lua.resume(lua, [1, 2])
    end

    test "tail return" do
      lua = yielder(Lua.new())
      {:suspended, _, lua} = Lua.eval!(lua, "return yield(9)")

      assert {:ok, [7], _} = Lua.resume(lua, [7])
    end

    test "call as argument" do
      lua = yielder(Lua.new())

      {:suspended, _, lua} =
        Lua.eval!(lua, "local function add(x, y) return x + y end return add(yield(), 100)")

      assert {:ok, [105], _} = Lua.resume(lua, [5])
    end

    test "vararg spread" do
      lua = yielder(Lua.new())

      {:suspended, _, lua} =
        Lua.eval!(lua, "local function f(...) local t = {...} return #t end return f(yield(1))")

      assert {:ok, [3], _} = Lua.resume(lua, [1, 2, 3])
    end

    test "discarded results" do
      lua = yielder(Lua.new())
      {:suspended, _, lua} = Lua.eval!(lua, "yield() return 42")

      assert {:ok, [42], _} = Lua.resume(lua, [1, 2])
    end

    test "extra resume values are dropped, missing ones are nil" do
      lua = yielder(Lua.new())
      {:suspended, _, lua} = Lua.eval!(lua, "local a = yield() return a")
      assert {:ok, [1], _} = Lua.resume(lua, [1, 2, 3])

      lua = yielder(Lua.new())
      {:suspended, _, lua} = Lua.eval!(lua, "local a, b = yield() return b == nil")
      assert {:ok, [true], _} = Lua.resume(lua, [1])
    end

    test "suspension works for pre-compiled chunks" do
      lua = yielder(Lua.new())
      {chunk, lua} = Lua.load_chunk!(lua, "return yield(3) + 1")

      assert {:suspended, [3], lua} = Lua.eval!(lua, chunk)
      assert {:ok, [42], _} = Lua.resume(lua, [41])
    end
  end

  describe "resume/3" do
    test "chained suspends resume one at a time" do
      lua = yielder(Lua.new())

      assert {:suspended, [1], lua} = Lua.eval!(lua, "local a = yield(1) return a + yield(a)")
      assert {:suspended, [10], lua} = Lua.resume(lua, [10])
      assert {:ok, [110], _} = Lua.resume(lua, [100])
    end

    test "suspend inside a numeric-for loop body" do
      lua = yielder(Lua.new())

      assert {:suspended, [1], lua} =
               Lua.eval!(lua, "local s = 0 for i = 1, 3 do s = s + yield(i) end return s")

      assert {:suspended, [2], lua} = Lua.resume(lua, [10])
      assert {:suspended, [3], lua} = Lua.resume(lua, [10])
      assert {:ok, [30], _} = Lua.resume(lua, [10])
    end

    test "suspend inside a generic-for loop body" do
      lua = yielder(Lua.new())

      code = """
      local function iter()
        local n = 0
        return function() n = n + 1 if n <= 2 then return n end end
      end
      local s = 0
      for i in iter() do s = s + yield(i) end
      return s
      """

      assert {:suspended, [1], lua} = Lua.eval!(lua, code)
      assert {:suspended, [2], lua} = Lua.resume(lua, [10])
      assert {:ok, [12], _} = Lua.resume(lua, [2])
    end

    test "heap effects made before the suspend are kept" do
      lua = yielder(Lua.new())
      {:suspended, _, lua} = Lua.eval!(lua, "g = 99 local a = yield() return a + g")

      assert {:ok, [100], _} = Lua.resume(lua, [1])
    end

    test "heap effects made before a post-resume error are kept" do
      lua = yielder(Lua.new())
      {:suspended, _, lua} = Lua.eval!(lua, "g = 5 local a = yield() return a + missing_global")

      assert {:error, exception, lua} = Lua.resume(lua, [1])
      assert %Lua.RuntimeException{} = exception
      assert lua.continuation == nil

      # The global write survived the error, matching pcall semantics
      assert {[5], _} = Lua.eval!(lua, "return g")
    end

    test "resume! returns the final values or suspends again" do
      lua = yielder(Lua.new())
      {:suspended, _, lua} = Lua.eval!(lua, "local a = yield(1) return a * 2")

      assert {[42], _} = Lua.resume!(lua, [21])
    end

    test "resume! reraises a post-resume Lua error" do
      lua = yielder(Lua.new())
      {:suspended, _, lua} = Lua.eval!(lua, "local a = yield() return a + nil")

      assert_raise Lua.RuntimeException, ~r/attempt to perform arithmetic/, fn ->
        Lua.resume!(lua, [1])
      end
    end

    test "resuming without a continuation raises ArgumentError" do
      assert_raise ArgumentError, ~r/no suspended continuation/, fn ->
        Lua.resume(Lua.new(), [])
      end
    end

    test "resuming a continuation with no layers raises ArgumentError" do
      lua = %{Lua.new() | continuation: %Continuation{layers: []}}

      assert_raise ArgumentError, ~r/no machine layers/, fn -> Lua.resume(lua, []) end
    end

    test "resume values must be a list" do
      lua = yielder(Lua.new())
      {:suspended, _, lua} = Lua.eval!(lua, "return yield(1)")

      assert_raise FunctionClauseError, fn -> Lua.resume(lua, :notalist) end
    end

    test "an unknown option raises instead of coming back as a Lua error" do
      lua = yielder(Lua.new())
      {:suspended, _, lua} = Lua.eval!(lua, "return yield(1)")

      assert_raise ArgumentError, fn -> Lua.resume(lua, [1], bogus: true) end
    end

    test "results are decoded like eval! results" do
      lua = yielder(Lua.new())
      {:suspended, [[{1, 1}, {2, 2}]], lua} = Lua.eval!(lua, "local a = yield({1, 2}) return {a, 3}")

      assert {:ok, [[{1, 1}, {2, 3}]], _} = Lua.resume(lua, [1])
    end

    test "the values of a further suspend are decoded too" do
      lua = yielder(Lua.new())
      {:suspended, [1], lua} = Lua.eval!(lua, "yield(1) return yield({k = 1})")

      assert {:suspended, [[{"k", 1}]], lua} = Lua.resume(lua, [])
      assert {[nil], _} = Lua.resume!(lua, [nil])
    end

    test "decode: false returns encoded values" do
      lua = yielder(Lua.new())
      {:suspended, _, lua} = Lua.eval!(lua, "local a = yield(1) return {a, 3}")

      assert {:ok, [%Table{}], _} = Lua.resume(lua, [1], decode: false)
    end

    test "an unrelated eval between suspend and resume preserves the continuation" do
      lua = yielder(Lua.new())
      {:suspended, _, lua} = Lua.eval!(lua, "local a = yield(1) return a + 1")

      assert {[99], lua} = Lua.eval!(lua, "return 99")
      assert {:ok, [42], _} = Lua.resume(lua, [41])
    end

    test ":max_instructions spans the whole suspend/resume cycle" do
      lua = [max_instructions: 50] |> Lua.new() |> yielder()

      assert {:suspended, [1], lua} =
               Lua.eval!(
                 lua,
                 "local a = yield(1) local s = 0 for i = 1, 1000 do s = s + i end return s"
               )

      # The tally carried in the continuation keeps counting across the
      # suspend point: the resumed loop trips the same budget.
      assert {:error, exception, _} = Lua.resume(lua, [1])
      assert Exception.message(exception) =~ "instruction budget exceeded"
    end

    test ":max_instructions counts Lua a callback ran before it suspended" do
      run_then = fn reply ->
        fn _args, lua ->
          {_, lua} = Lua.eval!(lua, "local s = 0 for i = 1, 6 do s = s + i end")
          reply.(lua)
        end
      end

      code = "work() local s = 0 for i = 1, 6 do s = s + i end return s"
      lua = Lua.new(max_instructions: 10)

      # Without a suspend, the two loops together exceed the budget.
      assert_raise Lua.RuntimeException, ~r/instruction budget exceeded/, fn ->
        Lua.eval!(Lua.set!(lua, [:work], run_then.(&{[1], &1})), code)
      end

      # A suspend between them must not refund the callback's loop.
      {:suspended, [1], lua} = Lua.eval!(Lua.set!(lua, [:work], run_then.(&{:suspend, [1], &1})), code)
      assert {:error, exception, _} = Lua.resume(lua, [])
      assert Exception.message(exception) =~ "instruction budget exceeded"
    end

    test ":max_instructions counts a suspending callback's Lua in a nested function" do
      lua =
        [max_instructions: 10]
        |> Lua.new()
        |> Lua.set!([:work], fn _args, lua ->
          {_, lua} = Lua.eval!(lua, "local s = 0 for i = 1, 6 do s = s + i end")
          {:suspend, [1], lua}
        end)

      code = "local function f() work() local s = 0 for i = 1, 6 do s = s + i end return s end return f()"
      {:suspended, [1], lua} = Lua.eval!(lua, code)
      assert {:error, exception, _} = Lua.resume(lua, [])
      assert Exception.message(exception) =~ "instruction budget exceeded"
    end

    test "a host exception after the resume comes back in the error tuple" do
      lua = Lua.new() |> yielder() |> Lua.set!([:bad], fn _args, _lua -> :not_a_result end)
      {:suspended, _, lua} = Lua.eval!(lua, "yield(1) return bad()")

      assert {:error, %Lua.RuntimeException{}, lua} = Lua.resume(lua, [])
      assert lua.continuation == nil
    end
  end

  describe "nested functions (dispatcher path)" do
    test "suspend inside a nested Lua function resumes through both engines" do
      lua = yielder(Lua.new())

      {:suspended, [5], lua} =
        Lua.eval!(lua, "local function f(x) return yield(x) + 1 end return f(5) * 2")

      assert {:ok, [22], _} = Lua.resume(lua, [10])
    end

    test "deep call stack" do
      lua = yielder(Lua.new())

      code = """
      local function g(x) return yield(x) end
      local function f(x) return g(x) + 1 end
      return f(1)
      """

      {:suspended, _, lua} = Lua.eval!(lua, code)
      assert {:ok, [11], _} = Lua.resume(lua, [10])
    end

    test "suspend inside a closure over an upvalue" do
      lua = yielder(Lua.new())

      code = """
      local function make()
        local n = 0
        return function(v)
          n = n + v
          yield(n)
          return n
        end
      end
      local f = make()
      f(1)
      return f(2)
      """

      assert {:suspended, [1], lua} = Lua.eval!(lua, code)
      assert {:suspended, [3], lua} = Lua.resume(lua, [])
      assert {:ok, [3], _} = Lua.resume(lua, [])
    end
  end

  describe "deflua" do
    test "deflua can suspend without threading state" do
      lua = Lua.load_api(Lua.new(), Scheduler)

      assert {:suspended, [7], lua} = Lua.eval!(lua, "return sched.yield(7) + 1")
      assert {:ok, [42], _} = Lua.resume(lua, [41])
    end

    test "deflua can thread state across the suspend" do
      lua = Lua.load_api(Lua.new(), Scheduler)

      assert {:suspended, [9], lua} = Lua.eval!(lua, "local a = sched.yield_with_state(9) return a")
      assert {[9], _} = Lua.eval!(lua, "return yielded")
      assert {:ok, [9], _} = Lua.resume(lua, [9])
    end

    test "a deflua that re-enters Lua and gets a suspend is a boundary error" do
      lua = Lua.load_api(Lua.new(), Scheduler)
      {[f], lua} = Lua.eval!(lua, "return function() return sched.yield(1) end", decode: false)

      assert {:error, exception, _lua} = Lua.call_function(lua, [:sched, :run], [f])
      assert %Lua.RuntimeException{} = exception
      assert Exception.message(exception) =~ @boundary_message
    end
  end

  describe "call_function/3" do
    test "calling a Lua closure that suspends returns {:suspended, ...}" do
      lua = yielder(Lua.new())
      {[f], lua} = Lua.eval!(lua, "return function(x) return yield(x) * 2 end", decode: false)

      assert {:suspended, [10], lua} = Lua.call_function(lua, f, [10])
      assert {:ok, [42], _} = Lua.resume(lua, [21])
    end

    test "calling a suspending native directly resumes with the resume values as results" do
      lua = yielder(Lua.new())

      assert {:suspended, [5], lua} = Lua.call_function(lua, [:yield], [5])
      assert {:ok, [77], _} = Lua.resume(lua, [77])
    end

    test "call_function! mirrors the suspended return" do
      lua = yielder(Lua.new())
      {[f], lua} = Lua.eval!(lua, "return function(x) return yield(x) * 2 end", decode: false)

      assert {:suspended, [10], lua} = Lua.call_function!(lua, f, [10])
      assert {[42], _} = Lua.resume!(lua, [21])
    end
  end

  describe "boundaries: a suspend that cannot resume is a catchable Lua error" do
    test "pcall around a suspending closure" do
      lua = yielder(Lua.new())

      assert {[false, @boundary_message], _} =
               Lua.eval!(lua, "return pcall(function() return yield(1) end)")
    end

    test "pcall with the suspending native as the protected function" do
      lua = yielder(Lua.new())

      assert {[false, @boundary_message], _} = Lua.eval!(lua, "return pcall(yield, 42)")
    end

    test "xpcall reports the boundary error to the message handler" do
      lua = yielder(Lua.new())

      assert {[false, "handled: " <> @boundary_message], _} =
               Lua.eval!(
                 lua,
                 "return xpcall(function() return yield(1) end, function(e) return 'handled: ' .. e end)"
               )
    end
  end

  # Each case runs outside `pcall`: the boundary error must come from the
  # site the suspend crosses, not from a surrounding protected call.
  # `after` is never reached: a suspend that is wrongly treated as
  # resumable would make `eval!` return `{:suspended, ...}` instead.
  @operator_cases [
    add: "local t = setmetatable({}, {__add = function() return yield('mm') end}) local x = t + 1",
    sub: "local t = setmetatable({}, {__sub = function() return yield('mm') end}) local x = t - 1",
    mul: "local t = setmetatable({}, {__mul = function() return yield('mm') end}) local x = t * 2",
    div: "local t = setmetatable({}, {__div = function() return yield('mm') end}) local x = t / 2",
    mod: "local t = setmetatable({}, {__mod = function() return yield('mm') end}) local x = t % 2",
    pow: "local t = setmetatable({}, {__pow = function() return yield('mm') end}) local x = t ^ 2",
    idiv: "local t = setmetatable({}, {__idiv = function() return yield('mm') end}) local x = t // 2",
    band: "local t = setmetatable({}, {__band = function() return yield('mm') end}) local x = t & 1",
    bor: "local t = setmetatable({}, {__bor = function() return yield('mm') end}) local x = t | 1",
    bxor: "local t = setmetatable({}, {__bxor = function() return yield('mm') end}) local x = t ~ 1",
    shl: "local t = setmetatable({}, {__shl = function() return yield('mm') end}) local x = t << 1",
    shr: "local t = setmetatable({}, {__shr = function() return yield('mm') end}) local x = t >> 1",
    bnot: "local t = setmetatable({}, {__bnot = function() return yield('mm') end}) local x = ~t",
    unm: "local t = setmetatable({}, {__unm = function() return yield('mm') end}) local x = -t",
    concat: "local t = setmetatable({}, {__concat = function() return yield('mm') end}) local x = t .. 'x'",
    len: "local t = setmetatable({}, {__len = function() return yield('mm') end}) local x = #t",
    eq:
      "local m = {__eq = function() return yield('mm') end} local a, b = setmetatable({}, m), setmetatable({}, m) local x = a == b",
    lt:
      "local m = {__lt = function() return yield('mm') end} local a, b = setmetatable({}, m), setmetatable({}, m) local x = a < b",
    le:
      "local m = {__le = function() return yield('mm') end} local a, b = setmetatable({}, m), setmetatable({}, m) local x = a <= b",
    le_via_lt:
      "local m = {__lt = function() return yield('mm') end} local a, b = setmetatable({}, m), setmetatable({}, m) local x = a <= b",
    native_metamethod: "local t = setmetatable({}, {__add = yield}) local x = t + 1"
  ]

  @callback_cases [
    index: "local t = setmetatable({}, {__index = function(_, k) return yield(k) end}) local x = t.foo",
    newindex: "local t = setmetatable({}, {__newindex = function(_, k, v) yield(v) end}) t.foo = 1",
    call: "local t = setmetatable({}, {__call = function(_, x) return yield(x) end}) local x = t(1)",
    tostring: "local t = setmetatable({}, {__tostring = function() return yield() end}) local x = tostring(t)",
    sort_comparator: "table.sort({3, 1, 2}, function(a, b) yield(a) return a < b end)",
    gsub: "string.gsub('abc', '.', function(s) yield(s) return s end)",
    generic_for: "local function iter() return function() yield() return nil end end for _ in iter() do end",
    ipairs_index:
      "local p = setmetatable({}, {__index = function(_, i) if i < 3 then return yield(i) end end}) for _ in ipairs(p) do end",
    unpack_index:
      "local p = setmetatable({}, {__index = function(_, i) return yield(i) end}) local x = table.unpack(p, 1, 1)",
    preload: "package.preload.m = function() return yield('pre') end local m = require('m')"
  ]

  defp assert_boundary(lua, code) do
    error = assert_raise Lua.RuntimeException, fn -> Lua.eval!(lua, code) end
    assert Exception.message(error) =~ @boundary_message
  end

  defp nested(body), do: "local function f() #{body} return 'inner' end local r = f() return 'after', r"

  describe "boundaries outside pcall: operator metamethods" do
    for {name, body} <- @operator_cases do
      @body body

      test "#{name} in the main chunk" do
        assert_boundary(yielder(Lua.new()), @body <> " return 'after', x")
      end

      test "#{name} in a nested function" do
        assert_boundary(yielder(Lua.new()), nested(@body))
      end
    end
  end

  describe "boundaries outside pcall: metamethod and stdlib callbacks" do
    for {name, body} <- @callback_cases do
      @body body

      test "#{name} in the main chunk" do
        assert_boundary(yielder(Lua.new(sandboxed: [])), @body <> " return 'after'")
      end

      test "#{name} in a nested function" do
        assert_boundary(yielder(Lua.new(sandboxed: [])), nested(@body))
      end
    end

    test "load reader function" do
      assert_boundary(
        yielder(Lua.new(sandboxed: [])),
        "local f = load(function() yield() return 'return 1' end) return 'after'"
      )
    end

    test "a pcall inside the metamethod still sees the boundary as a Lua error" do
      lua = yielder(Lua.new())

      assert {["after", msg], _} =
               Lua.eval!(
                 lua,
                 "local t = setmetatable({}, {__add = function() local _, e = pcall(yield, 1) return e end}) local e = t + 1 return 'after', e"
               )

      assert msg =~ @boundary_message
    end
  end
end
