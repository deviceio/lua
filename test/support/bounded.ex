defmodule Lua.Test.Bounded do
  @moduledoc false

  @doc """
  Evaluates `code` on `lua` in a time- and heap-capped worker, so a regressed
  resource guard fails instead of hanging or exhausting the host. The heap cap
  counts off-heap binaries too.

  Returns `{:ok, results}`, `{:raised, message}`, `:timeout`, or
  `{:error, reason}` (`:killed` when over the heap cap).
  """
  def eval(lua, code, opts \\ []) do
    heap_bytes = Keyword.get(opts, :heap_bytes, 512 * 1024 * 1024)
    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)
    parent = self()

    cap = %{
      size: div(heap_bytes, :erlang.system_info(:wordsize)),
      kill: true,
      error_logger: false,
      include_shared_binaries: true
    }

    worker = fn -> send(parent, {:bounded_result, self(), safe_eval(lua, code)}) end
    {pid, ref} = :erlang.spawn_opt(worker, [:monitor, max_heap_size: cap])

    receive do
      {:bounded_result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :timeout
        end
    end
  end

  defp safe_eval(lua, code) do
    {:ok, lua |> Lua.eval!(code) |> elem(0)}
  rescue
    e -> {:raised, Exception.message(e)}
  end
end
