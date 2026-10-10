defmodule Licet.GC do
  @moduledoc """
  Garbage collection of old relationship history.

  Licet keeps deleted and expired relationships, and the snapshots of past
  writes, for `gc_window` seconds, so that tokens from that window can still be
  read exactly. Every instance runs a collector that removes older history
  every `gc_interval` milliseconds, in batches of `gc_batch` rows.

  On several nodes, each pass takes a Postgres advisory lock, so only one node
  collects at a time. Set `gc_interval: false` to disable automatic passes, for
  example in tests or to trigger them from your own scheduler with `collect/1`.
  """

  use GenServer

  alias Licet.Store

  @doc false
  def child_spec(config), do: super(config)

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: name(config.name))
  end

  @doc false
  @spec name(atom()) :: module()
  def name(instance), do: Module.concat(instance, GC)

  @doc """
  Runs one collection pass on `instance` now and waits for it.

  Returns `:locked` when another node holds the lock and is collecting, and
  `{:error, %Licet.Error{reason: :not_started}}` when no instance with that
  name is running.

  ## Examples

      Licet.GC.collect(MyApp.Licet)
      #=> :ok
  """
  @spec collect(atom()) :: :ok | :locked | {:error, Licet.Error.t()}
  def collect(instance) when is_atom(instance) do
    case GenServer.whereis(name(instance)) do
      nil -> {:error, Licet.Error.new(:not_started, "#{inspect(instance)} is not running")}
      pid -> GenServer.call(pid, :collect, :infinity)
    end
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
