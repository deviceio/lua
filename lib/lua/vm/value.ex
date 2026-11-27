defmodule Lua.VM.Value do
  @moduledoc """
  Shared utilities for working with Lua values in the VM.

  Provides type inspection, truthiness, string conversion, number parsing,
  sequence length computation, and value encoding/decoding used by both
  the executor and stdlib.
  """

  alias Lua.Numeral
  alias Lua.VM.State

  @doc """
  Returns the Lua type name as a string for the given value.
  """
  @spec type_name(term()) :: String.t()
  def type_name(nil), do: "nil"
  def type_name(v) when is_boolean(v), do: "boolean"
  def type_name(v) when is_integer(v), do: "number"
  def type_name(v) when is_float(v), do: "number"
  def type_name(v) when is_binary(v), do: "string"
  def type_name({:tref, _}), do: "table"
  def type_name({:lua_closure, _, _}), do: "function"
  def type_name({:compiled_closure, _, _}), do: "function"
  def type_name({:native_func, _}), do: "function"
  def type_name({:udref, _}), do: "userdata"
  def type_name(_), do: "userdata"

  @doc """
  Returns whether a Lua value is truthy.

  In Lua, only `nil` and `false` are falsy. Everything else is truthy.
  """
  @spec truthy?(term()) :: boolean()
  def truthy?(nil), do: false
  def truthy?(false), do: false
  def truthy?(_), do: true

  @doc """
  Converts a Lua value to its string representation.
  """
  @spec to_string(term()) :: String.t()
  def to_string(nil), do: "nil"
  def to_string(true), do: "true"
  def to_string(false), do: "false"
  def to_string(v) when is_integer(v), do: Integer.to_string(v)

  def to_string(v) when is_float(v) do
    # Lua displays floats with at least one decimal place
    if v == Float.floor(v) and abs(v) < 1.0e15 do
      :erlang.float_to_binary(v, decimals: 1)
    else
      Float.to_string(v)
    end
  end

  def to_string(v) when is_binary(v), do: v

  def to_string({:tref, id}), do: "table: 0x#{address(id)}"

  # PUC-Lua renders functions as `function: 0x<addr>`; the suite and host
  # code that calls `tostring` on a function rely on the `function:` prefix.
  # There is no stable identity to print like a table's tref id, so derive a
  # deterministic pseudo-address from the term itself.
  def to_string({:lua_closure, _, _} = f), do: "function: 0x#{address(:erlang.phash2(f))}"
  def to_string({:compiled_closure, _, _} = f), do: "function: 0x#{address(:erlang.phash2(f))}"
  def to_string({:native_func, _} = f), do: "function: builtin: 0x#{address(:erlang.phash2(f))}"
  def to_string(other), do: inspect(other)

  defp address(id), do: String.pad_leading(Integer.to_string(id, 16), 14, "0")

  @doc """
  Converts a string to a number the way Lua 5.3 coerces strings, ignoring
  surrounding whitespace. Returns `nil` if the string is not a numeral.
  """
  @spec parse_number(String.t()) :: number() | nil
  def parse_number(str) do
    case Numeral.parse(String.trim(str)) do
      {:ok, number} -> number
      :error -> nil
    end
  end

  @doc """
  Computes the Lua sequence length of a table's data map.

  Finds the largest N where keys 1..N are all present.
  """
  @spec sequence_length(map()) :: non_neg_integer()
  def sequence_length(data) do
    do_sequence_length(data, 1)
  end

  defp do_sequence_length(data, n) do
    if Map.has_key?(data, n), do: do_sequence_length(data, n + 1), else: n - 1
  end

  # --- Encoding (Elixir → Lua VM) ---

  @doc """
  Encodes an Elixir value into the Lua VM's internal representation.

  Returns `{encoded_value, state}` since encoding maps and lists allocates tables.
  """
  @spec encode(term(), State.t(), (fun() -> term())) :: {term(), State.t()}
  def encode(value, state, fun_wrapper \\ &default_fun_wrapper/1)
  def encode(nil, state, _fun_wrapper), do: {nil, state}
  def encode(value, state, _fun_wrapper) when is_boolean(value), do: {value, state}
  def encode(value, state, _fun_wrapper) when is_number(value), do: {value, state}
  def encode(value, state, _fun_wrapper) when is_binary(value), do: {value, state}
  def encode(value, state, _fun_wrapper) when is_atom(value), do: {Atom.to_string(value), state}

  def encode(fun, state, fun_wrapper) when is_function(fun, 1) or is_function(fun, 2), do: {fun_wrapper.(fun), state}

  def encode({:userdata, value}, state, _fun_wrapper) do
    State.alloc_userdata(state, value)
  end

  # `decode/2` leaves a bare `{:tref, id}` wherever a table contains itself,
  # so a decoded cyclic value can carry one back in here. The id only means
  # anything against the state it was decoded from; passing it through live
  # would let a caller forge a reference into unrelated VM state.
  def encode({:tref, _} = ref, _state, _fun_wrapper) do
    raise Lua.RuntimeException,
          "cannot encode #{inspect(ref)} into a Lua value. This reference marks a " <>
            "cyclic table that decoding left in place rather than walking forever. " <>
            "Evaluate with `decode: false` to get a table reference that round-trips " <>
            "back into the VM."
  end

  # Structs are maps, so without this clause a bare `%MyStruct{}` would encode
  # to a Lua table carrying a `"__struct__"` key — a silent, lossy conversion.
  # Refuse it explicitly: the caller must decide how the struct maps to a Lua
  # value. Protocol-based struct encoding is planned (see issue #341); raising
  # now keeps that future addition additive rather than a breaking change.
  def encode(%mod{}, _state, _fun_wrapper) do
    raise Lua.RuntimeException,
          "cannot encode #{inspect(mod)} struct into a Lua value. Convert it to a " <>
            "plain map first (e.g. `Map.from_struct/1`), selecting only the fields " <>
            "Lua needs. Protocol-based struct encoding is planned (issue #341)."
  end

  def encode(map, state, fun_wrapper) when is_map(map) do
    {data, state} =
      Enum.reduce(map, {%{}, state}, fn {k, v}, {data, state} ->
        key = if is_atom(k), do: Atom.to_string(k), else: k
        {encoded_v, state} = encode(v, state, fun_wrapper)
        {Map.put(data, key, encoded_v), state}
      end)

    State.alloc_table(state, data)
  end

  def encode(list, state, fun_wrapper) when is_list(list) do
    if keyword_list?(list) do
      {data, state} =
        Enum.reduce(list, {%{}, state}, fn {k, v}, {data, state} ->
          key = Atom.to_string(k)
          {encoded_v, state} = encode(v, state, fun_wrapper)
          {Map.put(data, key, encoded_v), state}
        end)

      State.alloc_table(state, data)
    else
      {data, state} =
        list
        |> Enum.with_index(1)
        |> Enum.reduce({%{}, state}, fn {v, idx}, {data, state} ->
          {encoded_v, state} = encode(v, state, fun_wrapper)
          {Map.put(data, idx, encoded_v), state}
        end)

      State.alloc_table(state, data)
    end
  end

  # Default function wrapper, preserving the raw-state calling convention for
  # low-level callers. `Lua.set!/3` and `Lua.encode!/2` inject their own
  # wrapper so callbacks receive the public `t:Lua.t/0` instead.
  defp default_fun_wrapper(fun) when is_function(fun, 2), do: {:native_func, fun}

  defp default_fun_wrapper(fun) when is_function(fun, 1) do
    {:native_func, fn args, st -> {List.wrap(fun.(args)), st} end}
  end

  @doc """
  Encodes a list of Elixir values, threading state through each encoding.

  Returns `{encoded_values, state}`.
  """
  @spec encode_list([term()], State.t()) :: {[term()], State.t()}
  def encode_list(values, state) do
    {reversed, state} =
      Enum.reduce(values, {[], state}, fn v, {acc, state} ->
        {encoded, state} = encode(v, state)
        {[encoded | acc], state}
      end)

    {Enum.reverse(reversed), state}
  end

  defp keyword_list?([{k, _v} | rest]) when is_atom(k), do: keyword_list?(rest)
  defp keyword_list?([]), do: true
  defp keyword_list?(_), do: false

  # --- Decoding (Lua VM → Elixir) ---

  @doc """
  Decodes a Lua VM value into an Elixir-friendly representation.

  Tables are returned as lists of `{key, decoded_value}` tuples.
  Functions (closures, native) pass through as-is.

  Cyclic tables (e.g. the common `T.__index = T` idiom) cannot be
  represented as acyclic Elixir data, so the walk terminates at the
  point of recurrence and leaves the table's `{:tref, id}` reference
  there — mirroring how functions already pass through as opaque
  references. Shared references that do not form a cycle decode
  normally.
  """
  @spec decode(term(), State.t()) :: term()
  def decode(value, state), do: decode(value, state, %{})

  defp decode(nil, _state, _ancestors), do: nil
  defp decode(value, _state, _ancestors) when is_boolean(value), do: value
  defp decode(value, _state, _ancestors) when is_number(value), do: value
  defp decode(value, _state, _ancestors) when is_binary(value), do: value

  defp decode({:udref, _} = ref, state, _ancestors) do
    value = State.get_userdata(state, ref)
    {:userdata, value}
  end

  defp decode({:tref, id} = ref, state, ancestors) do
    if Map.has_key?(ancestors, id) do
      ref
    else
      table = Map.fetch!(state.tables, id)
      ancestors = Map.put(ancestors, id, true)

      Enum.map(Lua.VM.Table.to_map(table), fn {k, v} -> {k, decode(v, state, ancestors)} end)
    end
  end

  defp decode(value, _state, _ancestors), do: value

  @doc """
  Decodes a list of Lua VM values.
  """
  @spec decode_list([term()], State.t()) :: [term()]
  def decode_list(values, state) do
    Enum.map(values, &decode(&1, state))
  end
end
