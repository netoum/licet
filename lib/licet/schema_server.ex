defmodule Licet.SchemaServer do
  @moduledoc false

  use GenServer

  alias Licet.Error
  alias Licet.Schema
  alias Licet.Store

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: name(config.name))
  end

  @spec name(atom()) :: module()
  def name(instance), do: Module.concat(instance, SchemaServer)

  @spec get(atom()) :: {:ok, map()} | {:error, Error.t()}
  def get(instance) do
    case :persistent_term.get({Licet, instance, :schema}, :missing) do
      :missing -> {:error, Error.new(:not_started, "#{inspect(instance)} has no schema")}
      schema -> {:ok, schema}
    end
  end

  @spec put(atom(), map()) :: :ok
  def put(instance, schema) do
    :persistent_term.put({Licet, instance, :schema}, schema)
    :ok
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    case load(config) do
      {:ok, schema} ->
        put(config.name, schema)
        {:ok, config}

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl true
  def terminate(_reason, config) do
    :persistent_term.erase({Licet, config.name, :schema})
    :ok
  end

  defp load(config) do
    if Store.migrated?(config.repo, config.prefix) do
      install(config)
    else
      {:error,
       Error.new(:not_migrated, "run the licet migration before starting #{inspect(config.name)}")}
    end
  end

  defp install(config) do
    with {:ok, current} <- Store.current_schema(config.repo, config.prefix),
         {:ok, source} <- configured_source(config, current) do
      publish(config, current, source)
    end
  end

  defp configured_source(%{schema: nil}, current), do: {:ok, current || ""}

  defp configured_source(%{schema: {:string, source}}, _current), do: {:ok, source}

  defp configured_source(%{schema: {:file, path}}, _current) do
    case File.read(path) do
      {:ok, source} ->
        {:ok, source}

      {:error, reason} ->
        {:error, Error.new(:invalid_schema, "cannot read schema file: #{inspect(reason)}")}
    end
  end

  defp publish(_config, current, current) when is_binary(current) and current != "" do
    Schema.parse(current)
  end

  defp publish(_config, _current, "") do
    {:ok, empty()}
  end

  defp publish(config, current, source) do
    with {:ok, parsed} <- Schema.parse(source),
         {:ok, old} <- parse_old(current),
         :ok <- write_if_needed(config, old, parsed, source) do
      {:ok, parsed}
    end
  end

  defp parse_old(nil), do: {:ok, nil}
  defp parse_old(""), do: {:ok, nil}

  defp parse_old(source), do: Schema.parse(source)

  defp write_if_needed(config, old, parsed, source) do
    config.repo.transaction(fn -> commit_schema(config, old, parsed, source) end)
    |> unwrap()
  end

  defp commit_schema(config, old, parsed, source) do
    case Store.ensure_compatible(config.repo, config.prefix, old, parsed) do
      :ok -> finish_schema(config, source, parsed.hash)
      {:error, error} -> config.repo.rollback(error)
    end
  end

  defp finish_schema(config, source, hash) do
    {:ok, _token} = Store.write_schema(config.repo, config.prefix, source, hash, %{})
    :ok
  end

  defp unwrap({:ok, :ok}), do: :ok
  defp unwrap({:error, %Error{} = error}), do: {:error, error}

  defp empty do
    %{definitions: %{}, expiration: false, source: "", hash: hash("")}
  end

  defp hash(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end
end
