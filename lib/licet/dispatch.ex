defmodule Licet.Dispatch do
  @moduledoc false

  alias Licet.Cache
  alias Licet.Error

  @spec compute(atom(), term(), non_neg_integer(), (-> result)) :: result
        when result: {:ok, :allowed | :denied} | {:error, Error.t()}
  def compute(instance, key, timeout, fun) when is_function(fun, 0) do
    case cached(instance, key) do
      {:ok, value} -> {:ok, value}
      :miss -> register(instance, key, timeout, fun)
    end
  end

  @doc false
  @spec cached(atom(), term()) :: {:ok, :allowed | :denied} | :miss
  def cached(instance, key) do
    case Cache.fetch(instance, key) do
      {:ok, value} ->
        event(:hit)
        {:ok, value}

      :miss ->
        event(:miss)
        :miss
    end
  end

  @doc false
  @spec put(atom(), term(), result) :: result
        when result: {:ok, :allowed | :denied} | {:error, Error.t()}
  def put(instance, key, result), do: store(instance, key, result)

  @doc false
  @spec registries(atom()) :: [Supervisor.child_spec()]
  def registries(instance) do
    [
      Supervisor.child_spec({Registry, keys: :unique, name: owners(instance)},
        id: owners(instance)
      ),
      Supervisor.child_spec({Registry, keys: :duplicate, name: waiters(instance)},
        id: waiters(instance)
      )
    ]
  end

  defp register(instance, key, timeout, fun) do
    case Registry.register(owners(instance), key, nil) do
      {:ok, _pid} ->
        try do
          store(instance, key, fun.())
        after
          Registry.unregister(owners(instance), key)
          notify(instance, key)
        end

      {:error, {:already_registered, owner}} ->
        wait(instance, key, owner, timeout, fun)
    end
  end

  defp store(instance, key, {:ok, value} = result) do
    Cache.put(instance, key, value)
    result
  end

  defp store(_instance, _key, {:error, error}), do: {:error, error}

  defp notify(instance, key) do
    Registry.dispatch(waiters(instance), key, fn entries ->
      Enum.each(entries, fn {_pid, ref} -> send(ref, {ref, :settled}) end)
    end)
  end

  # The owner keeps running after it stores the result, so a waiter is told
  # through its monitor alias rather than by the owner exiting. Registering
  # before looking at the owner again means a result stored in between is
  # either seen here or announced to the alias. Removing the monitor also
  # deactivates the alias, so a late announcement never reaches the mailbox.
  defp wait(instance, key, owner, timeout, fun) do
    ref = Process.monitor(owner, alias: :demonitor)
    {:ok, _pid} = Registry.register(waiters(instance), key, ref)
    unless owner?(instance, key, owner), do: send(ref, {ref, :settled})

    try do
      await(instance, key, ref, timeout, fun)
    after
      Process.demonitor(ref, [:flush])
      Registry.unregister(waiters(instance), key)
    end
  end

  defp await(instance, key, ref, timeout, fun) do
    receive do
      {^ref, :settled} -> settled(instance, key, fun)
      {:DOWN, ^ref, _, _, _} -> settled(instance, key, fun)
    after
      timeout -> expire(instance, key, ref, timeout, fun)
    end
  end

  # Like `GenServer.call/3`, the mailbox is read once more after the alias is
  # deactivated, so an announcement that arrived just in time is used rather
  # than left behind.
  defp expire(_instance, _key, _ref, 0, _fun),
    do: {:error, Error.new(:timeout, "check timed out")}

  defp expire(instance, key, ref, _timeout, fun) do
    Process.demonitor(ref, [:flush])
    await(instance, key, ref, 0, fun)
  end

  defp owner?(instance, key, owner) do
    match?([{^owner, _value}], Registry.lookup(owners(instance), key))
  end

  defp settled(instance, key, fun) do
    case Cache.fetch(instance, key) do
      {:ok, value} -> {:ok, value}
      :miss -> fun.()
    end
  end

  defp owners(instance), do: Module.concat(instance, Registry)
  defp waiters(instance), do: Module.concat(instance, Waiters)

  defp event(kind) do
    :telemetry.execute([:licet, :cache, kind], %{count: 1}, %{})
  end
end
