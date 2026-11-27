defmodule Lua.VM.ProtectedCall do
  @moduledoc false

  # The Lua-facing error value handed back at a protected-call boundary
  # (`pcall`/`xpcall`, and `Lua.call_function/3`), per §6.1: the raised value
  # passes through verbatim.
  #
  # `caught_value/1` replaces host exception messages, which can quote host
  # data, with `"error in host function"`.
  #
  # `error_value/1` clause ordering is load-bearing:
  # 1. `error()`'s §6.1-prefixed string view (`RuntimeError.lua_value`).
  # 2. Raw passthrough on KEY PRESENCE — `value: nil` (from `error()`) and
  #    `value: false` must match here so the boundary returns nil/false like
  #    PUC-Lua, never an `is_nil`-guarded fallthrough to the next clause.
  # 3. `ArgumentError` builds its message from individual fields and has no
  #    `:value` slot, so it gets its own clause that returns the raw
  #    `"bad argument #N to 'F' ..."` string — never the terminal-rendered
  #    `Exception.message/1` (ANSI + location header).
  alias Lua.VM.ArgumentError
  alias Lua.VM.AssertionError
  alias Lua.VM.RuntimeError
  alias Lua.VM.TypeError

  @vm_errors [RuntimeError, AssertionError, TypeError, ArgumentError]

  @host_error_message "error in host function"

  def caught_value(exception), do: caught_value(exception, raised_for_script?(exception))

  defp caught_value(%module{} = vm_error, true) when module in @vm_errors, do: error_value(vm_error)
  defp caught_value(runtime_exception, true), do: Exception.message(runtime_exception)
  defp caught_value(_host_exception, false), do: @host_error_message

  defp raised_for_script?(%module{}) when module in @vm_errors, do: true

  defp raised_for_script?(%Lua.RuntimeException{original: original}) when is_exception(original),
    do: raised_for_script?(original)

  defp raised_for_script?(%Lua.RuntimeException{}), do: true
  defp raised_for_script?(_host_exception), do: false

  def error_value(%{lua_value: lv}) when not is_nil(lv), do: lv
  def error_value(%{value: value}), do: value
  def error_value(%ArgumentError{} = e), do: ArgumentError.raw_message(e)
end
