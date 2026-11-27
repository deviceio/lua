defmodule Lua.VM.Display do
  @moduledoc """
  Boundary wrappers that turn opaque VM value tags into display
  structs at the `Lua.eval!/2` return path.

  The internal VM continues to use the tagged-tuple representation
  (`{:tref, id}`, `{:lua_closure, proto, upvalues}`,
  `{:native_func, fun}`, `{:udref, id}`). These wrappers exist
  purely so that values that surface to user code in `iex` render
  legibly instead of as opaque tuples.

  See `Lua.VM.Display.Table`, `Lua.VM.Display.Closure`,
  `Lua.VM.Display.NativeFunc`, and `Lua.VM.Display.Userdata` for
  the per-tag display structs and their `Inspect` impls.

  ## Decode behaviour

  | Tag                    | `decode: true`                   | `decode: false`              |
  |------------------------|----------------------------------|------------------------------|
  | `{:tref, _}`           | list of `{k, v}` (unchanged)     | wraps to `Display.Table`     |
  | `{:udref, _}`          | `{:userdata, term}` (unchanged)  | wraps to `Display.Userdata`  |
  | `{:lua_closure, _, _}` | wraps to `Display.Closure`       | wraps to `Display.Closure`   |
  | `{:native_func, _}`    | wraps to `Display.NativeFunc`    | wraps to `Display.NativeFunc`|

  Default-decode tables and userdata are left in their existing
  Elixir-friendly shape so `deflua` flows and downstream consumers
  do not need to change.
  """

  alias Lua.VM.Display.Closure
  alias Lua.VM.Display.NativeFunc
  alias Lua.VM.Display.Table, as: DTable
  alias Lua.VM.Display.Userdata
  alias Lua.VM.Limits
  alias Lua.VM.State
  alias Lua.VM.Table

  @typedoc "Any of the four display structs produced at the eval boundary."
  @type display_struct ::
          DTable.t()
          | Closure.t()
          | NativeFunc.t()
          | Userdata.t()

  @doc """
  Wraps each value in a list of eval results for display, given the
  state at boundary-cross time and the `decode:` option.

  When `decode: true` (the default), tables and userdata are passed
  through unchanged because they have already been decoded into
  Elixir-friendly shapes (list of tuples and `{:userdata, term}`).
  Closures and native funcs are wrapped in either mode.

  When `decode: false`, all four tag kinds are wrapped and table peeks
  are walked like `Lua.VM.Value.decode_list/2`: shared tables once, with
  tables past `state.max_decode_nodes` marked `:truncated`.
  """
  @spec wrap_results([term()], State.t(), boolean()) :: [term()]
  def wrap_results(values, state, false) when is_list(values) do
    {wrapped, _walk} = Enum.map_reduce(values, {%{}, 0}, &peek_result(&1, state, &2))
    wrapped
  end

  def wrap_results(values, _state, _decode?) when is_list(values), do: Enum.map(values, &wrap_callable/1)

  @doc """
  Returns true when the value is one of the four display structs.

  Used by API entry points (`Lua.set!/3`, `Lua.encode!/2`, etc.) to
  detect a wrapped-for-display value that should be unwrapped back
  to its underlying VM tag before further processing.
  """
  @spec display_struct?(term()) :: boolean()
  def display_struct?(%DTable{}), do: true
  def display_struct?(%Closure{}), do: true
  def display_struct?(%NativeFunc{}), do: true
  def display_struct?(%Userdata{}), do: true
  def display_struct?(_), do: false

  @doc """
  Unwraps a display struct back to its underlying VM tag tuple.

  Returns the value unchanged if it is not a display struct.
  """
  @spec unwrap(term()) :: term()
  def unwrap(%DTable{ref: ref}), do: ref
  def unwrap(%Closure{ref: ref}), do: ref
  def unwrap(%NativeFunc{ref: ref}), do: ref
  def unwrap(%Userdata{ref: ref}), do: ref
  def unwrap(other), do: other

  @doc """
  Wraps a single eval-result value for display.

  See `wrap_results/3` for the decode-mode matrix.

  Tables that (transitively) contain themselves get a `:circular`
  peek at the point of recurrence rather than recursing forever —
  see `Lua.VM.Display.Table`.
  """
  @spec wrap_value(term(), State.t(), boolean()) :: term()
  def wrap_value(value, state, decode?) do
    [wrapped] = wrap_results([value], state, decode?)
    wrapped
  end

  # ---- internal helpers ----

  defp wrap_callable({tag, _, _} = ref) when tag in [:lua_closure, :compiled_closure], do: wrap_closure(ref)
  defp wrap_callable({:native_func, fun} = ref), do: %NativeFunc{fun: fun, ref: ref}
  defp wrap_callable(value), do: value

  # Budgeted like `Lua.VM.Value.decode_list/2`, but truncates instead of
  # raising, so a result whose own node no longer fits is still wrapped.
  defp peek_result(value, state, {memo, nodes_used} = walk) do
    case Limits.reserve_decode_nodes(nodes_used, 1, state.max_decode_nodes) do
      {:ok, nodes_used} -> peek_value(value, state, {memo, nodes_used})
      :exhausted -> peek_value(value, state, walk)
    end
  end

  defp peek_value({:tref, id} = ref, state, {memo, _nodes_used} = walk) do
    case memo do
      %{^id => {peeked_table, subtree_nodes}} -> reuse_peek(peeked_table, subtree_nodes, state, walk)
      %{^id => :in_progress} -> {wrap_table(ref, :circular), walk}
      %{} -> peek_table(ref, state, walk)
    end
  end

  defp peek_value({:udref, id} = ref, state, walk) do
    {%Userdata{id: id, term: State.get_userdata(state, ref), ref: ref}, walk}
  end

  defp peek_value(value, _state, walk), do: {wrap_callable(value), walk}

  defp wrap_closure({tag, proto, _upvalues} = ref) when tag in [:lua_closure, :compiled_closure] do
    {first_line, _last_line} = proto.lines || {0, 0}

    %Closure{
      source: proto.source,
      line: first_line,
      arity: proto.param_count,
      vararg?: proto.is_vararg,
      upvalue_names: proto.upvalue_names,
      ref: ref
    }
  end

  # Build a `peek` value for an unencoded table reference. Sequences
  # (1..N keys) render as a list; mixed-key tables render as a map.
  # Nested tables/closures are recursively wrapped so `Inspect` does
  # not have to know about live VM state.
  defp peek_table({:tref, id} = ref, state, {memo, nodes_used} = walk) do
    with {:ok, table} <- Map.fetch(state.tables, id),
         {:ok, nodes_used_with_entries} <-
           Limits.reserve_decode_nodes(nodes_used, Table.entry_count(table), state.max_decode_nodes) do
      {peek, {memo, nodes_used_after}} =
        peek_entries(Table.to_map(table), state, {Map.put(memo, id, :in_progress), nodes_used_with_entries})

      peeked_table = wrap_table(ref, peek)
      {peeked_table, {Map.put(memo, id, {peeked_table, nodes_used_after - nodes_used}), nodes_used_after}}
    else
      # Stale or detached reference: the `id` is enough to identify it.
      :error -> {wrap_table(ref, []), walk}
      :exhausted -> {wrap_table(ref, :truncated), walk}
    end
  end

  defp reuse_peek(peeked_table, subtree_nodes, state, {memo, nodes_used} = walk) do
    case Limits.reserve_decode_nodes(nodes_used, subtree_nodes, state.max_decode_nodes) do
      {:ok, nodes_used} -> {peeked_table, {memo, nodes_used}}
      :exhausted -> {%{peeked_table | peek: :truncated}, walk}
    end
  end

  defp peek_entries(entries, state, walk) do
    if sequence_like?(entries) do
      Enum.map_reduce(1..map_size(entries), walk, &peek_value(Map.fetch!(entries, &1), state, &2))
    else
      {peeked_entries, walk} = Enum.map_reduce(entries, walk, &peek_entry(&1, state, &2))
      {Map.new(peeked_entries), walk}
    end
  end

  defp peek_entry({key, value}, state, walk) do
    {peeked, walk} = peek_value(value, state, walk)
    {{key, peeked}, walk}
  end

  defp wrap_table({:tref, id} = ref, peek), do: %DTable{id: id, peek: peek, ref: ref}

  defp sequence_like?(data) when map_size(data) == 0, do: false

  defp sequence_like?(data) do
    Enum.all?(1..map_size(data), &Map.has_key?(data, &1))
  end
end
