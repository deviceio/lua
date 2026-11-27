defmodule Lua.VM.LimitBypassTest do
  @moduledoc """
  Each script runs heap-capped with a timeout, on both the dispatcher and
  the interpreter.
  """
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Compiler.Prototype
  alias Lua.Parser
  alias Lua.VM

  @timeout 15_000
  @heap_words div(256 * 1024 * 1024, :erlang.system_info(:wordsize))

  @budget [max_instructions: 10_000]
  @depth [max_call_depth: 100]
  @budget_and_depth [max_instructions: 10_000, max_call_depth: 100]

  @engines [:dispatcher, :interpreter]

  defp run_isolated(code, engine, opts) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: @heap_words, kill: true, error_logger: false})
        send(parent, {:result, self(), compile_and_run(code, engine, opts)})
      end)

    receive do
      {:result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("#{engine}: script died (#{inspect(reason)}) instead of raising a Lua error:\n#{code}")
    after
      @timeout ->
        Process.exit(pid, :kill)
        flunk("#{engine}: script did not terminate within #{@timeout}ms:\n#{code}")
    end
  end

  defp compile_and_run(code, engine, opts) do
    {:ok, ast} = Parser.parse(code)
    {:ok, proto} = Compiler.compile(ast, source: "limits.lua")
    proto = if engine == :interpreter, do: strip_bytecode(proto), else: proto
    {:ok, results, _state} = VM.execute(proto, lua_with_host_callback(opts).state)
    {:ok, results}
  rescue
    e -> {:error, Map.get(e, :value) || Exception.message(e)}
  end

  defp lua_with_host_callback(opts) do
    Lua.set!(Lua.new(opts), [:call_with_self], fn [function | args], lua ->
      Lua.call_function!(lua, function, [function | args])
    end)
  end

  defp strip_bytecode(%Prototype{} = proto) do
    %{proto | bytecode: nil, prototypes: Enum.map(proto.prototypes, &strip_bytecode/1)}
  end

  defp assert_raises_lua(code, opts, message) do
    for engine <- @engines do
      assert {:error, value} = run_isolated(code, engine, opts), "#{engine}: expected #{inspect(message)} for:\n#{code}"
      assert is_binary(value) and value =~ message, "#{engine}: expected #{inspect(message)}, got #{inspect(value)}"
    end
  end

  defp assert_recursion_bounded(code) do
    assert_raises_lua(code, @budget_and_depth, "stack overflow")
    assert_raises_lua(code, @depth, "stack overflow")
    assert_raises_lua(code, @budget, "instruction budget exceeded")
  end

  defp assert_results(code, opts, expected) do
    for engine <- @engines do
      assert expected == results!(code, engine, opts)
    end
  end

  defp results!(code, engine, opts) do
    assert {:ok, results} = run_isolated(code, engine, opts), "#{engine}: unexpected error for:\n#{code}"
    results
  end

  describe "backward goto" do
    test "in the main chunk exhausts the budget" do
      code = "local n = 0 ::top:: n = n + 1 if n < 1e9 then goto top end return n"
      assert_raises_lua(code, @budget, "instruction budget exceeded")
    end

    test "in a function exhausts the budget" do
      code = """
      local function spin()
        local n = 0
        ::top::
        n = n + 1
        if n < 1e9 then goto top end
        return n
      end
      return spin()
      """

      assert_raises_lua(code, @budget, "instruction budget exceeded")
    end

    test "out of a loop exhausts the budget" do
      code = """
      local function spin()
        local n = 0
        ::again::
        for i = 1, 2 do
          n = n + 1
          if n < 1e9 then goto again end
        end
        return n
      end
      return spin()
      """

      assert_raises_lua(code, @budget, "instruction budget exceeded")
    end

    test "loop that ends under the budget returns" do
      assert_results("local n = 0 ::top:: n = n + 1 if n < 100 then goto top end return n", @budget, [100])
    end

    test "forward gotos are free" do
      jumps = Enum.map_join(1..40, " ", fn i -> "do goto l#{i} end ::l#{i}::" end)
      assert_results("local function f() #{jumps} return 1 end #{jumps} return f()", [max_instructions: 5], [1])
    end
  end

  describe "host re-entry" do
    test "pcall recursion stops at :max_call_depth" do
      code = "local function f() return pcall(f) end return f()"

      for engine <- @engines, opts <- [@depth, @budget_and_depth] do
        results = results!(code, engine, opts)
        assert List.last(results) =~ "stack overflow"
        assert length(results) <= 102
      end
    end

    test "pcall recursion stops at :max_instructions" do
      code = "local function f() return pcall(f) end return f()"

      for engine <- @engines do
        assert List.last(results!(code, engine, @budget)) =~ "instruction budget exceeded"
      end
    end

    test "counting pcall recursion stops at either limit" do
      code = "local n = 0 local function f() n = n + 1 local ok = pcall(f) return ok end f() return n"

      for engine <- @engines do
        assert [call_count] = results!(code, engine, @depth)
        assert call_count in 1..100

        assert [call_count] = results!(code, engine, @budget)
        assert call_count in 1..10_000
      end
    end

    test "recursive xpcall handler terminates" do
      code = "local function f() return xpcall(error, f) end return f()"

      for engine <- @engines, opts <- [@depth, @budget, @budget_and_depth] do
        assert [false | _] = results!(code, engine, opts)
      end
    end

    # `for _ in it, nil, nil`: a bare `for _ in it` hits an unrelated
    # register-allocation bug.
    for {name, code} <- [
          {"string.gsub replacement", ~S|local function f() return (("x"):gsub("x", f)) end return f()|},
          {"table.sort comparator", "local function f() table.sort({2, 1}, f) return true end return f()"},
          {"__tostring via tostring",
           "local t t = setmetatable({}, {__tostring = function(a) return tostring(a) end}) return tostring(t)"},
          {"generic-for iterator", "local function it() for _ in it, nil, nil do end end for _ in it, nil, nil do end"},
          {"__index", "local t t = setmetatable({}, {__index = function(_, k) return t[k] end}) return t.x"},
          {"__newindex", "local t t = setmetatable({}, {__newindex = function(_, k, v) t[k] = v end}) t.x = 1"},
          {"__add", "local t t = setmetatable({}, {__add = function(a, b) return a + b end}) return t + 1"},
          {"__unm", "local t t = setmetatable({}, {__unm = function(a) return -a end}) return -t"},
          {"__concat", ~S|local t t = setmetatable({}, {__concat = function(a, b) return a .. b end}) return t .. "x"|},
          {"__len", "local t t = setmetatable({}, {__len = function(a) return #a end}) return #t"},
          {"__lt", "local mt = {} mt.__lt = function(a, b) return a < b end local t = setmetatable({}, mt) return t < t"},
          {"__eq",
           "local mt = {} mt.__eq = function(a, b) return a == b end return setmetatable({}, mt) == setmetatable({}, mt)"},
          {"__call calling its table",
           "local t = setmetatable({}, {__call = function(self) return self() end}) return t()"},
          {"native __tostring",
           "local t = setmetatable({}, {}) getmetatable(t).__tostring = tostring return tostring(t)"},
          {"host callback through Lua.call_function!/3", "local function f() return call_with_self(f) end return f()"},
          {"host callback calling itself through Lua.call_function!/3", "return call_with_self(call_with_self)"}
        ] do
      test name, do: assert_recursion_bounded(unquote(code))
    end

    for {name, comparator} <- [{"Lua", "function(a, b) return a < b end"}, {"native", "rawequal"}] do
      test "table.sort charges each #{name} comparator call" do
        code = """
        local t = {}
        for i = 1, 3000 do t[i] = i end
        return pcall(table.sort, t, #{unquote(comparator)})
        """

        for engine <- @engines do
          assert [false, err] = results!(code, engine, @budget)
          assert err =~ "instruction budget exceeded"
        end
      end
    end

    test "native __call calling its table" do
      code = "local t = setmetatable({}, {__call = pcall}) return t()"

      for engine <- @engines do
        assert List.last(results!(code, engine, @depth)) =~ "stack overflow"
        assert List.last(results!(code, engine, @budget)) =~ "instruction budget exceeded"
      end
    end
  end

  # Each of the 400 iterations runs ~100 instructions behind a bridge:
  # counted in full, the total is four times the budget.
  describe "work behind a metamethod bridge" do
    @spin_loop "local s = 0 for j = 1, 100 do s = s + j end"

    test "stays counted when a native call follows" do
      code = """
      local t = setmetatable({}, {__index = function() #{@spin_loop} return 1 end})
      local function run() local n = 0 for i = 1, 400 do n = n + t.x; type(n) end return n end
      return run()
      """

      assert_raises_lua(code, @budget, "instruction budget exceeded")
    end

    for {name, failure} <- [{"an arithmetic error", "return nil + {}"}, {"a stack overflow", "return deep()"}] do
      test "stays counted after #{name} is caught" do
        code = """
        local function deep() return 1 + deep() end
        local function run() for i = 1, 400 do pcall(function() #{@spin_loop} #{unquote(failure)} end) end end
        return run()
        """

        assert_raises_lua(code, @budget_and_depth, "instruction budget exceeded")
      end
    end
  end

  describe "call depth is released" do
    @define_deep "local function deep(n) if n == 0 then return 0 end return 1 + deep(n - 1) end"

    test "after a caught stack overflow" do
      code = """
      local function f() return pcall(f) end
      local first = select('#', f())
      local second = select('#', f())
      #{@define_deep}
      return first == second, deep(90)
      """

      assert_results(code, @budget_and_depth, [true, 90])
    end

    test "after calls return" do
      code = """
      local proxy = setmetatable({}, {__index = function(_, k) return k end})
      local s = 0
      for i = 1, 300 do s = s + proxy[i] end
      for i = 1, 300 do pcall(function() end) end
      for i = 1, 300 do table.sort({3, 1, 2}, function(a, b) return a < b end) end
      local callable = setmetatable({}, {__call = function(_, x) return x end})
      for i = 1, 300 do s = s + callable(1) end
      #{@define_deep}
      return s, deep(90)
      """

      assert_results(code, [max_call_depth: 100], [45_450, 90])
    end

    test "after caught errors" do
      code = """
      local raising = setmetatable({}, {__index = function() error("boom") end})
      for i = 1, 300 do pcall(function() return raising.x end) end
      #{@define_deep}
      return deep(90)
      """

      assert_results(code, [max_call_depth: 100], [90])
    end

    test "default limits allow deep pcall recursion" do
      code = "local function f(n) if n == 0 then return 0 end local _, v = pcall(f, n - 1) return v + 1 end return f(300)"
      assert_results(code, [], [300])
    end
  end

  describe "__call chain" do
    for {name, code} <- [
          {"self-referential", "local a = {} setmetatable(a, {__call = a}) return a()"},
          {"self-referential in a function",
           "local function f() local a = {} setmetatable(a, {__call = a}) return a() end return f()"},
          {"self-referential as a for iterator",
           "local a = setmetatable({}, {}) getmetatable(a).__call = a for _ in a, nil, nil do end"}
        ] do
      test name, do: assert_raises_lua(unquote(code), [], "'__call' chain too long; possible loop")
    end

    test "self-referential under pcall is catchable" do
      code = """
      local a = {} setmetatable(a, {__call = a})
      local ok, err = pcall(a)
      return ok, err, 1 + 1
      """

      for engine <- @engines do
        assert [false, err, 2] = results!(code, engine, [])
        assert err =~ "'__call' chain too long"
      end
    end

    test "short chain resolves" do
      # Each hop inserts the callable it went through ahead of the arguments.
      code = """
      local inner
      inner = setmetatable({}, {__call = function(self, outer_tbl, x) return self == inner, outer_tbl, x end})
      local outer = setmetatable({}, {__call = inner})
      local is_inner, got_outer, x = outer(42)
      return is_inner, got_outer == outer, x
      """

      assert_results(code, [], [true, true, 42])
    end
  end
end
