defmodule Licet.Cache do
  @moduledoc false

  use GenServer

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: name(config.name))
  end

  @spec name(atom()) :: module()
  def name(instance), do: Module.concat(instance, Cache)

  @spec table(atom()) :: module()
  def table(instance), do: Module.concat(instance, CacheTable)

  @spec fetch(atom(), term()) :: {:ok, :allowed | :denied} | :miss
  def fetch(instance, key) do
    case :ets.lookup(table(instance), key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  @spec put(atom(), term(), :allowed | :denied) :: true
  def put(instance, key, value) when value in [:allowed, :denied] do
    :ets.insert(table(instance), {key, value})
  end

  @impl true
  def init(config) do
    :ets.new(table(config.name), [:named_table, :public, :set, read_concurrency: true])
    {:ok, config.name}
  end
end
