defmodule Lua.PcallHostErrorTest do
  use ExUnit.Case, async: true

  @host_error_message "error in host function"

  defmodule HostAPI do
    @moduledoc false
    use Lua.API, scope: "host"

    deflua match_error() do
      {:ok, _} = Process.get(:unset_host_value, {:error, "secret-token"})
    end

    deflua function_clause(value) do
      String.upcase(value)
    end

    deflua argument_error(id) do
      raise ArgumentError, "employee #{id} not found in tenant acme"
    end

    deflua deliberate() do
      runtime_exception!("employee not found")
    end

    deflua error_tuple() do
      {:error, "employee not found"}
    end

    deflua call_back(callback), state do
      Lua.call_function!(state, callback, [])
    end
  end

  defp eval!(code), do: Lua.new() |> Lua.load_api(HostAPI) |> Lua.eval!(code) |> elem(0)

  describe "pcall over a host exception" do
    for call <- ["host.match_error()", "host.function_clause(42)", "host.argument_error(7)"] do
      test "#{call} reaches the script as the generic message" do
        assert [false, @host_error_message] = eval!("return pcall(function() return #{unquote(call)} end)")
      end
    end

    test "an xpcall message handler receives the generic message" do
      assert [false, "handled: " <> @host_error_message] =
               eval!(~S[return xpcall(host.match_error, function(message) return "handled: " .. message end)])
    end

    test "a host exception wrapped by a nested Lua.call_function! stays hidden" do
      assert [false, @host_error_message] =
               eval!("return pcall(host.call_back, function() return host.match_error() end)")
    end

    test "a Lua.set!/3 function returning unencoded data reaches the script as the generic message" do
      lua = Lua.set!(Lua.new(), [:lookup], fn [_id] -> {:error, "secret-token"} end)

      assert {[false, @host_error_message], _} = Lua.eval!(lua, ~s|return pcall(lookup, "employee-42")|)
    end
  end

  describe "uncaught host exception" do
    test "still reaches the host on :original" do
      lua = Lua.load_api(Lua.new(), HostAPI)

      exception = assert_raise Lua.RuntimeException, fn -> Lua.eval!(lua, "return host.match_error()") end

      assert %MatchError{term: {:error, "secret-token"}} = exception.original
      assert exception.kind == nil
    end
  end

  describe "errors raised for the script" do
    test "runtime_exception!/1 reaches pcall unchanged" do
      assert [false, "Lua runtime error: host.deliberate() failed, employee not found"] =
               eval!("return pcall(host.deliberate)")
    end

    test "an {:error, reason} return reaches pcall unchanged" do
      assert [false, "employee not found"] = eval!("return pcall(host.error_tuple)")
    end

    test "a Lua error raised through a nested Lua.call_function! reaches pcall" do
      assert [false, error_value] = eval!(~S[return pcall(host.call_back, function() error("boom", 0) end)])

      assert error_value =~ "boom"
    end
  end
end
