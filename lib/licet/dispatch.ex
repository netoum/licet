defmodule Licet.Dispatch do
  @moduledoc false

  alias Licet.Cache
  alias Licet.Error

  @spec compute(atom(), term(), non_neg_integer(), (-> result)) :: result
        when result: {:ok, :allowed | :denied} | {:error, Error.t()}
  def compute(instance, key, timeout, fun) when is_function(fun, 0) do
    case Cache.fetch(instance, key) do
      {:ok, value} ->
        event(:hit)
        {:ok, value}

      :miss ->
        event(:miss)
        register(instance, key, timeout, fun)
    end
  end

  defp register(instance, key, timeout, fun) do
    case Registry.register(Module.concat(instance, Registry), key, nil) do
      {:ok, _pid} ->
        try do
          store(instance, key, fun.())
        after
          Registry.unregister(Module.concat(instance, Registry), key)
        end

      {:error, {:already_registered, pid}} ->
        wait(instance, key, pid, timeout, fun)
    end
  end

  defp store(instance, key, {:ok, value} = result) do
    Cache.put(instance, key, value)
    result
  end

  defp store(_instance, _key, {:error, error}), do: {:error, error}

  defp wait(instance, key, pid, timeout, fun) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, _, _, _} ->
        case Cache.fetch(instance, key) do
          {:ok, value} -> {:ok, value}
          :miss -> fun.()
        end
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, Error.new(:timeout, "check timed out")}
    end
  end

  defp event(kind) do
    :telemetry.execute([:licet, :cache, kind], %{count: 1}, %{})
  end
end
