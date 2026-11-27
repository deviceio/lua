defmodule Lua.VM.Limits do
  @moduledoc """
  Practical resource ceilings for stdlib operations whose output can be far
  larger than their arguments.

  These guard against denial-of-service via a single oversized allocation
  (e.g. `string.rep("x", 1e15)`, `table.unpack(t, 1, 1e12)`). Each call
  site computes the result size *before* allocating and asks here whether
  it is permitted, turning what would otherwise be an out-of-memory crash
  of the host into a catchable Lua error.

  PUC-Lua raises the same messages — "resulting string too large" on
  `size_t` overflow in `str_rep`, and "too many results to unpack" on the
  `INT_MAX` guard in `unpack`. The thresholds here sit far above any
  legitimate embedded use; they are the same guards at a practical bound
  rather than at the machine word size.

  This is the deterministic, OTP-independent layer: it never relies on the
  garbage collector or heap accounting to notice a bomb, because the bomb
  is refused before a byte is allocated.

  Work a stdlib call does outside the dispatch loop is charged to the
  `:max_instructions` budget in units: a byte scanned or built, an element
  visited or returned, a pattern-matcher step. See `charge!/2`.
  """

  alias Lua.VM.ArgumentError
  alias Lua.VM.RuntimeError
  alias Lua.VM.State

  # 256 MiB. A single string this large is already pathological for an
  # embedded interpreter; legitimate snippets never approach it.
  @max_string_bytes 256 * 1024 * 1024

  # PUC-Lua's `LUAI_MAXSTACK`.
  @max_element_count 1_000_000

  # Sixteen units cost about the CPU of one Lua loop iteration.
  @work_per_instruction 16

  @doc "The string-size ceiling, in bytes."
  @spec max_string_bytes() :: pos_integer()
  def max_string_bytes, do: @max_string_bytes

  @doc "The default element-count ceiling (`:max_table_elements`)."
  @spec max_element_count() :: pos_integer()
  def max_element_count, do: @max_element_count

  @doc "Units of native work charged as one instruction."
  @spec work_per_instruction() :: pos_integer()
  def work_per_instruction, do: @work_per_instruction

  @doc """
  Charges `units` of native work to `:max_instructions`, one instruction per
  `work_per_instruction/0` units. Call it before the work, so an over-budget
  call raises without doing it.
  """
  @spec charge!(State.t(), integer()) :: State.t()
  def charge!(%{max_instructions: :infinity} = state, _units), do: state
  def charge!(state, units) when units < @work_per_instruction, do: state

  def charge!(%{max_instructions: max, instruction_count: tally} = state, units) do
    case tally + div(units, @work_per_instruction) do
      charged when charged < max -> %{state | instruction_count: charged}
      _overdrawn -> State.tick!(state, max - 1)
    end
  end

  @doc "Like `charge!/2`, one unit per element of `list`."
  @spec charge_elements!(State.t(), list()) :: State.t()
  def charge_elements!(%{max_instructions: :infinity} = state, _list), do: state
  def charge_elements!(state, list), do: charge!(state, length(list))

  @doc """
  Asserts that an as-yet-unallocated string of `bytes` bytes is within the
  given ceiling (a state's `max_string_bytes`, defaulting to the practical
  bound here). Raises a catchable "resulting string too large" runtime
  error otherwise.

  Pass `state` when Lua code ran between the native call's entry and this
  check (a `string.gsub` callback, a `table.concat` `__index`): the raise
  then carries it, so a protected call keeps that code's heap effects.
  """
  # `max` may be `:infinity` (from `Lua.new(max_string_bytes: :infinity)`).
  # Erlang term ordering places every number below every atom, so an integer
  # `bytes <= :infinity` is always true and the check passes unconditionally —
  # no separate clause is needed.
  @spec check_string_size!(integer(), pos_integer() | :infinity, State.t() | nil) :: :ok
  def check_string_size!(bytes, max \\ @max_string_bytes, state \\ nil)

  def check_string_size!(bytes, max, _state) when is_integer(bytes) and bytes <= max, do: :ok

  def check_string_size!(_bytes, _max, state) do
    raise RuntimeError, value: "resulting string too large", state: state
  end

  @doc """
  Raises a catchable `"range too large"` bad-argument error, attributed to
  `function_name`, when `count` exceeds `max` (`:infinity` always passes).
  """
  @spec check_range_count!(integer(), pos_integer() | :infinity, String.t()) :: :ok
  def check_range_count!(count, max, _function_name) when is_integer(count) and count <= max, do: :ok

  def check_range_count!(_count, _max, function_name) do
    raise ArgumentError, function_name: function_name, details: "range too large"
  end

  @doc """
  Raises a catchable `"string slice too long"` error when `count` exceeds `max`.
  """
  @spec check_slice_count!(integer(), pos_integer() | :infinity) :: :ok
  def check_slice_count!(count, max) when is_integer(count) and count <= max, do: :ok

  def check_slice_count!(_count, _max) do
    raise RuntimeError, value: "string slice too long"
  end

  @doc """
  Raises a catchable `"too many results"` error when `count` exceeds `max`.
  """
  @spec check_result_count!(integer(), pos_integer() | :infinity) :: :ok
  def check_result_count!(count, max) when is_integer(count) and count <= max, do: :ok

  def check_result_count!(_count, _max) do
    raise RuntimeError, value: "too many results"
  end
end
