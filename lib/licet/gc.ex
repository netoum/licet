defmodule Licet.GC do
  @moduledoc """
  Deletes relationship tombstones and expired tuples outside the consistency window.

  One node holds a session advisory lock, so a cluster does not collect the same
  rows twice.
  """

  use GenServer

  alias Licet.Store

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: name(config.name))
  end

  @spec name(atom()) :: module()
  def name(instance), do: Module.concat(instance, GC)

  @spec collect(atom()) :: :ok | :locked | {:error, Licet.Error.t()}
  def collect(instance) do
    GenServer.call(name(instance), :collect, :infinity)
  end

  @impl true
  def init(config) do
    if config.gc_interval, do: schedule(config)
    {:ok, config}
  end

  @impl true
  def handle_call(:collect, _from, config) do
    {:reply, run(config), config}
  end

  @impl true
  def handle_info(:gc, config) do
    _ = run(config)
    schedule(config)
    {:noreply, config}
  end

  defp schedule(%{gc_interval: interval}) when is_integer(interval) do
    Process.send_after(self(), :gc, interval)
  end

  defp schedule(_config), do: :ok

  defp run(config) do
    key = :erlang.phash2({:licet_gc, config.prefix})

    config.repo.checkout(fn ->
      with {:ok, locked} <- Store.try_lock(config.repo, key) do
        collect_locked(config, key, locked)
      end
    end)
  end

  defp collect_locked(config, key, true) do
    Store.collect(config.repo, config.prefix, config.gc_window, config.gc_batch)
  after
    Store.unlock(config.repo, key)
  end

  defp collect_locked(_config, _key, false), do: :locked
end
