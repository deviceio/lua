defmodule Lua.VM.Suspend do
  @moduledoc false

  # Internal control-flow signal raised by a `deflua` / Elixir callback that
  # returns `{:suspend, values}` (or `{:suspend, values, %Lua{}}`).
  #
  # Not a Lua error: it is never wrapped into `Lua.RuntimeException` and never
  # handed to `pcall` as an error value. It travels from the callback's raise
  # site up to the nearest VM call boundary, where the executor/dispatcher
  # catch it and attach a resumable machine layer (`layers`). Every other
  # re-entry goes through `Lua.VM.Executor.call_function/3`, which turns it
  # into a `Lua.VM.RuntimeError` because resumption is impossible there
  # (operator metamethods, `__index` / `__newindex` / `__call`, generic-for
  # iterators, stdlib callbacks); `pcall`/`xpcall` and re-entrant natives
  # report it the same way.
  #
  # Fields:
  #
  #   * `:values` — encoded Lua values yielded to the host.
  #   * `:state` — the `Lua.VM.State` at the suspend point (heap effects
  #     made before the suspend are kept, like VM error exceptions).
  #   * `:layers` — `nil` until a catch site attaches the continuation layer
  #     stack (innermost first). `nil` means "suspended directly at this
  #     native call"; a non-nil list means a nested machine suspended and
  #     each enclosing engine boundary pushed its own layer.
  alias Lua.VM.RuntimeError

  defexception [:values, :state, :layers]

  @type t :: %__MODULE__{}

  @impl true
  def message(%__MODULE__{}), do: "suspend"

  @doc """
  The error message used when a suspend crosses a native call boundary.
  """
  @spec boundary_message() :: String.t()
  def boundary_message, do: "attempt to suspend across a native call boundary"

  @doc """
  The instruction tally to park in the innermost continuation layer.

  A callback may run Lua (`Lua.call_function!/3`, `Lua.eval!/3`) before it
  suspends, so the state it suspends with can carry a higher tally than
  the machine had when it made the call. Resume seeds the tally from the
  layer, so parking the lower one would refund that work.
  """
  @spec tally(t(), non_neg_integer()) :: non_neg_integer()
  def tally(%__MODULE__{state: %{instruction_count: count}}, at_call) when is_integer(count), do: max(count, at_call)
  def tally(%__MODULE__{}, at_call), do: at_call

  @doc """
  Raises the boundary error for a suspend that cannot be resumed.

  `fallback_state` is used when the exception carries no state of its own.
  `:line`/`:source`/`:call_stack` are passed through to the
  `Lua.VM.RuntimeError`; when omitted, the runtime error's `exception/1`
  fills them from the process-dictionary source position.
  """
  @spec raise_boundary!(t(), keyword()) :: no_return()
  def raise_boundary!(%__MODULE__{} = e, opts) do
    state = e.state || Keyword.get(opts, :fallback_state)
    call_stack = Keyword.get(opts, :call_stack) || (state && state.call_stack) || []

    raise RuntimeError,
      value: boundary_message(),
      state: state,
      call_stack: call_stack,
      line: Keyword.get(opts, :line),
      source: Keyword.get(opts, :source)
  end
end
