defmodule Lua.VM.DecodeLimitsTest do
  @moduledoc "Pins shared-table decoding and the `:max_decode_nodes` ceiling."

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Lua.VM.Display.Table, as: DTable
  alias Lua.VM.Limits
  alias Lua.VM.State
  alias Lua.VM.Table
  alias Lua.VM.Value

  @heap_cap_bytes 64 * 1024 * 1024
  @time_cap_ms 10_000

  describe "shared tables" do
    test "the default limit refuses a doubling DAG" do
      # 2^28 nodes once expanded, from a script well inside its instruction budget.
      exception = assert_too_large(fn -> Lua.eval!(Lua.new(max_instructions: 10_000), doubling(28)) end)
      assert Exception.message(exception) =~ ":max_decode_nodes (#{Limits.max_decode_nodes()})"
    end

    test "decode to one shared term per table" do
      levels = 16

      assert {:ok, facts} =
               bounded(fn ->
                 {[decoded], _} = Lua.eval!(Lua.new(), doubling(levels))
                 [{1, left}, {2, right}] = decoded
                 expected = doubled_term(levels)

                 %{
                   equal?: decoded === expected,
                   shared?: :erts_debug.same(left, right),
                   size: :erts_debug.size(decoded),
                   expected_size: :erts_debug.size(expected),
                   flat_size: :erts_debug.flat_size(decoded)
                 }
               end)

      assert facts.equal?
      assert facts.shared?
      assert facts.size == facts.expected_size
      assert facts.flat_size > 1_000 * facts.size
    end

    test ":infinity decodes in memory linear in the distinct tables" do
      levels = 64

      assert {:ok, facts} =
               bounded(fn ->
                 lua = Lua.new(max_decode_nodes: :infinity)
                 {[decoded], _} = Lua.eval!(lua, doubling(levels))
                 %{size: :erts_debug.size(decoded), depth: spine_depth(decoded)}
               end)

      # 2^65 nodes expanded: never compare or flatten it.
      assert facts.size == :erts_debug.size(doubled_term(levels))
      assert facts.depth == levels
    end
  end

  describe "node counting" do
    test "the value and each table entry count as one node" do
      # 1 + 3 + 2
      code = "return {1, 2, {3, 4}}"

      assert {[[{1, 1}, {2, 2}, {3, [{1, 3}, {2, 4}]}]], _} =
               Lua.eval!(Lua.new(max_decode_nodes: 6), code)

      assert_too_large(fn -> Lua.eval!(Lua.new(max_decode_nodes: 5), code) end)
      assert {[42], _} = Lua.eval!(Lua.new(max_decode_nodes: 1), "return 42")
    end

    test "a shared table counts once per place it appears" do
      # 1 + 2 + 2 × 2
      code = "local s = {1, 2} return {s, s}"

      assert {[[{1, inner}, {2, inner}]], _} = Lua.eval!(Lua.new(max_decode_nodes: 7), code)
      assert inner == [{1, 1}, {2, 2}]
      assert_too_large(fn -> Lua.eval!(Lua.new(max_decode_nodes: 6), code) end)
    end

    test "a cycle cut counts as one node" do
      code = "local t = {} t.self = t return t"

      assert {[[{"self", {:tref, _}}]], _} = Lua.eval!(Lua.new(max_decode_nodes: 2), code)
      assert_too_large(fn -> Lua.eval!(Lua.new(max_decode_nodes: 1), code) end)
    end

    test "the limit spans all values an eval returns" do
      # 3 × (1 + 3)
      code = "local s = {1, 2, 3} return s, s, s"

      assert {[first, second, third], _} = Lua.eval!(Lua.new(max_decode_nodes: 12), code)
      assert first == [{1, 1}, {2, 2}, {3, 3}]
      assert :erts_debug.same(first, second) and :erts_debug.same(second, third)
      assert_too_large(fn -> Lua.eval!(Lua.new(max_decode_nodes: 11), code) end)
    end
  end

  describe "cyclic tables" do
    test "a cyclic table reached by another path keeps its first cuts" do
      code = """
      local a = {}
      local b = {a = a}
      a.b = b
      return {x = a, y = b}
      """

      {[decoded], _} = Lua.eval!(Lua.new(), code)

      assert [{"x", [{"b", b_under_x}]}, {"y", b_under_y}] = decoded
      assert [{"a", {:tref, _}}] = b_under_x
      assert :erts_debug.same(b_under_x, b_under_y)
    end

    test "a cyclic table under two keys is shared" do
      code = "local T = {} T.__index = T return {x = T, y = T}"

      assert {[[{"x", x}, {"y", y}]], _} = Lua.eval!(Lua.new(), code)
      assert [{"__index", {:tref, _}}] = x
      assert :erts_debug.same(x, y)
    end

    test "a strongly connected tangle decodes linearly" do
      # Every table points back at `top`: one cycle with 2^levels paths from it.
      tangle = fn levels ->
        """
        local top = {}
        local t = {top}
        for _ = 1, #{levels} do t = {t, t, top} end
        top[1] = t
        return top
        """
      end

      assert_too_large(fn ->
        Lua.eval!(Lua.new(max_instructions: 10_000, max_decode_nodes: 1_000), tangle.(28))
      end)

      assert {:ok, facts} =
               bounded(fn ->
                 lua = Lua.new(max_decode_nodes: :infinity)
                 {[big], _} = Lua.eval!(lua, tangle.(28))
                 {[small], _} = Lua.eval!(lua, tangle.(10))
                 [{1, [_, _, {3, {:tref, top_id}}]}] = small

                 %{
                   big_size: :erts_debug.size(big),
                   small_equal?: small === tangle_term(10, {:tref, top_id})
                 }
               end)

      assert facts.big_size < 30 * 28
      assert facts.small_equal?
    end
  end

  describe "deep nesting" do
    test "thousands of nested levels decode and peek" do
      levels = 10_000
      code = "local t = {} for _ = 1, #{levels} do t = {t} end return t"

      assert {:ok, facts} =
               bounded(fn ->
                 {[decoded], _} = Lua.eval!(Lua.new(), code)
                 {[peek], _} = Lua.eval!(Lua.new(), code, decode: false)

                 %{
                   equal?: decoded == Enum.reduce(1..levels, [], fn _, inner -> [{1, inner}] end),
                   peek_depth: peek_depth(peek)
                 }
               end)

      assert facts.equal?
      assert facts.peek_depth == levels
    end

    test "a deep chain past the limit is refused" do
      code = "local t = {} for _ = 1, 10000 do t = {t} end return t"
      assert_too_large(fn -> Lua.eval!(Lua.new(max_decode_nodes: 5_000), code) end)
    end
  end

  describe ":max_decode_nodes option" do
    test "defaults to 5 million" do
      assert Limits.max_decode_nodes() == 5_000_000
      assert Lua.new().state.max_decode_nodes == Limits.max_decode_nodes()
      assert %State{}.max_decode_nodes == Limits.max_decode_nodes()
    end

    test "accepts a positive integer or :infinity" do
      assert Lua.new(max_decode_nodes: 1).state.max_decode_nodes == 1
      assert Lua.new(max_decode_nodes: 123_456).state.max_decode_nodes == 123_456
      assert Lua.new(max_decode_nodes: :infinity).state.max_decode_nodes == :infinity
    end

    test "rejects anything else" do
      for bad <- [0, -1, 1.5, :none, "100", nil] do
        assert_raise ArgumentError,
                     ~r/:max_decode_nodes must be a positive integer or :infinity, got: /,
                     fn -> Lua.new(max_decode_nodes: bad) end
      end
    end
  end

  describe "entry points" do
    setup do
      %{lua: Lua.new(max_instructions: 10_000, max_decode_nodes: 100)}
    end

    test "eval! of a precompiled chunk", %{lua: lua} do
      {:ok, chunk} = Lua.parse_chunk(doubling(28))
      assert_too_large(fn -> Lua.eval!(lua, chunk) end)
    end

    test "get!/3", %{lua: lua} do
      {_, lua} = Lua.eval!(lua, doubling(28, "big = t"))

      assert_too_large(fn -> Lua.get!(lua, [:big]) end)
      assert {:tref, _} = Lua.get!(lua, [:big], decode: false)
    end

    test "decode!/2", %{lua: lua} do
      # `get!/3` with `decode: false` takes no display peek, so nothing outside
      # `bounded/1` walks the table.
      {_, lua} = Lua.eval!(lua, doubling(28, "big = t"))
      ref = Lua.get!(lua, [:big], decode: false)

      assert_too_large(fn -> Lua.decode!(lua, ref) end)
    end

    test "decode_list!/2 shares one budget across the list" do
      {refs, lua} =
        Lua.eval!(Lua.new(max_decode_nodes: 12), "local s = {1, 2, 3} return s, s, s", decode: false)

      assert [first, second, third] = Lua.decode_list!(lua, refs)
      assert :erts_debug.same(first, second) and :erts_debug.same(second, third)

      tight = %{lua | state: %{lua.state | max_decode_nodes: 11}}
      assert_too_large(fn -> Lua.decode_list!(tight, refs) end)
    end

    test "decode: false truncates the peek instead of raising", %{lua: lua} do
      assert {:ok, facts} =
               bounded(fn ->
                 {[peeked], _} = Lua.eval!(lua, doubling(28), decode: false)
                 rendered = inspect(peeked, limit: :infinity)

                 %{
                   nodes: 1 + peek_nodes(peeked),
                   truncated?: rendered =~ "truncated",
                   bytes: byte_size(rendered)
                 }
               end)

      assert facts.nodes <= 100
      assert facts.truncated?
      assert facts.bytes < 10_000
    end

    test "decode: false shares peeks and truncates at the exact budget" do
      # 1 + 2 + 1 × 2
      code = "local s = {1} return {s, s}"

      {[peeked], _} = Lua.eval!(Lua.new(max_decode_nodes: 5), code, decode: false)
      assert %DTable{peek: [%DTable{peek: [1]} = first, second]} = peeked
      assert :erts_debug.same(first, second)

      {[peeked], _} = Lua.eval!(Lua.new(max_decode_nodes: 4), code, decode: false)
      assert %DTable{peek: [%DTable{peek: [1]}, %DTable{peek: :truncated} = cut]} = peeked
      assert inspect(cut) == "#Lua.Table<id: #{cut.id}, truncated>"
    end
  end

  describe "acyclic values" do
    property "trees decode as a path-by-path walk" do
      check all(data <- tree_gen(), max_runs: 200) do
        {ref, state} = Value.encode(data, State.new())
        assert Value.decode(ref, state) === decode_path_by_path(ref, state)
      end
    end

    property "shared tables decode as a path-by-path walk, in less memory" do
      check all(tables <- graph_gen(), max_runs: 200) do
        {root, state} = build_graph(tables, :acyclic)
        decoded = Value.decode(root, state)
        expected = decode_path_by_path(root, state)

        assert decoded === expected
        assert :erts_debug.size(decoded) <= :erts_debug.size(expected)
      end
    end
  end

  describe "arbitrary graphs" do
    property "the limit equals the expanded size" do
      check all(tables <- graph_gen(), max_runs: 200) do
        {root, state} = build_graph(tables, :any)
        full = Value.decode(root, %{state | max_decode_nodes: :infinity})
        nodes = expanded_nodes(full)

        assert Value.decode(root, %{state | max_decode_nodes: nodes}) === full

        if nodes > 1 do
          assert_too_large(fn -> Value.decode(root, %{state | max_decode_nodes: nodes - 1}) end)
        end
      end
    end

    property "every cut is a table on a cycle" do
      check all(tables <- graph_gen(), max_runs: 200) do
        {root, state} = build_graph(tables, :any)

        for id <- cut_ids(Value.decode(root, state)) do
          assert reaches?(state, id, id), "table #{id} was cut but is not on a cycle"
        end
      end
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp doubling(levels, finish \\ "return t"), do: "local t = {} for _ = 1, #{levels} do t = {t, t} end #{finish}"

  defp doubled_term(levels), do: Enum.reduce(1..levels, [], fn _, inner -> [{1, inner}, {2, inner}] end)

  defp tangle_term(levels, cut) do
    inner = Enum.reduce(1..levels, [{1, cut}], fn _, inner -> [{1, inner}, {2, inner}, {3, cut}] end)
    [{1, inner}]
  end

  defp spine_depth([{1, inner} | _]), do: 1 + spine_depth(inner)
  defp spine_depth([]), do: 0

  defp peek_depth(%DTable{peek: [inner]}), do: 1 + peek_depth(inner)
  defp peek_depth(%DTable{peek: peek}) when peek == %{}, do: 0

  defp peek_nodes(%DTable{peek: peek}) when is_list(peek) do
    Enum.reduce(peek, 0, fn value, count -> count + 1 + peek_nodes(value) end)
  end

  defp peek_nodes(%DTable{peek: peek}) when is_map(peek) do
    Enum.reduce(peek, 0, fn {_key, value}, count -> count + 1 + peek_nodes(value) end)
  end

  defp peek_nodes(_), do: 0

  defp expanded_nodes(decoded), do: 1 + nodes_below(decoded)

  defp nodes_below(table) when is_list(table) do
    Enum.reduce(table, 0, fn {_key, value}, count -> count + 1 + nodes_below(value) end)
  end

  defp nodes_below(_), do: 0

  defp cut_ids({:tref, id}), do: [id]
  defp cut_ids(table) when is_list(table), do: Enum.flat_map(table, fn {_key, value} -> cut_ids(value) end)
  defp cut_ids(_), do: []

  defp reaches?(state, from, target), do: reaches?(state, children(state, from), target, MapSet.new())

  defp reaches?(_state, [], _target, _seen), do: false
  defp reaches?(_state, [target | _], target, _seen), do: true

  defp reaches?(state, [id | rest], target, seen) do
    if MapSet.member?(seen, id) do
      reaches?(state, rest, target, seen)
    else
      reaches?(state, children(state, id) ++ rest, target, MapSet.put(seen, id))
    end
  end

  defp children(state, id) do
    for {_k, {:tref, child}} <- Table.to_map(Map.fetch!(state.tables, id)), do: child
  end

  defp assert_too_large(fun) do
    assert {:raised, %Lua.RuntimeException{} = exception} = bounded(fun)
    assert Exception.message(exception) =~ "decoded value exceeds :max_decode_nodes"
    exception
  end

  defp decode_path_by_path(value, state), do: decode_path_by_path(value, state, %{})

  defp decode_path_by_path({:tref, id} = ref, _state, ancestors) when is_map_key(ancestors, id), do: ref

  defp decode_path_by_path({:tref, id}, state, ancestors) do
    ancestors = Map.put(ancestors, id, true)

    Enum.map(Table.to_map(Map.fetch!(state.tables, id)), fn {key, value} ->
      {key, decode_path_by_path(value, state, ancestors)}
    end)
  end

  defp decode_path_by_path({:udref, _} = ref, state, _ancestors), do: {:userdata, State.get_userdata(state, ref)}
  defp decode_path_by_path(value, _state, _ancestors), do: value

  defp tree_gen do
    leaf = one_of([integer(), float(), boolean(), string(:alphanumeric, max_length: 6)])
    key = string(:alphanumeric, min_length: 1, max_length: 4)

    leaf
    |> tree(fn child ->
      one_of([
        list_of(child, max_length: 40),
        map_of(key, child, max_length: 40)
      ])
    end)
    |> resize(30)
  end

  # Each entry is a scalar or a `{:ref, seed}` that `build_graph/2` resolves to a table.
  defp graph_gen do
    key = one_of([integer(1..6), string(:alphanumeric, min_length: 1, max_length: 3)])
    entry = one_of([tuple({constant(:scalar), integer()}), tuple({constant(:ref), non_negative_integer()})])
    list_of(map_of(key, entry, max_length: 4), min_length: 1, max_length: 8)
  end

  # Under `:acyclic`, table `i` only points at earlier tables. The root is the last one.
  defp build_graph(tables, mode) do
    count = length(tables)

    {refs, state} =
      Enum.map_reduce(1..count, State.new(), fn _, state -> State.alloc_table(state) end)

    state =
      tables
      |> Enum.with_index()
      |> Enum.reduce(state, fn {entries, index}, state ->
        State.update_table(state, Enum.at(refs, index), fn table ->
          Enum.reduce(entries, table, fn {key, entry}, table ->
            Table.put(table, key, resolve(entry, refs, index, mode))
          end)
        end)
      end)

    {List.last(refs), state}
  end

  defp resolve({:scalar, value}, _refs, _index, _mode), do: value
  defp resolve({:ref, seed}, _refs, 0, :acyclic), do: seed
  defp resolve({:ref, seed}, refs, index, :acyclic), do: Enum.at(refs, rem(seed, index))
  defp resolve({:ref, seed}, refs, _index, :any), do: Enum.at(refs, rem(seed, length(refs)))

  # Runs `fun` in a heap- and time-capped process so a regression fails
  # instead of exhausting the machine. Only send back small facts: message
  # passing copies a term without its sharing.
  defp bounded(fun) do
    parent = self()
    tag = make_ref()
    words = div(@heap_cap_bytes, :erlang.system_info(:wordsize))

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              {:ok, fun.()}
            rescue
              exception -> {:raised, exception}
            end

          send(parent, {tag, result})
        end,
        [:monitor, max_heap_size: %{size: words, kill: true, error_logger: false}]
      )

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:exit, reason}
    after
      @time_cap_ms ->
        Process.exit(pid, :kill)
        :timeout
    end
  end
end
