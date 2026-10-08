defmodule Licet.Revision do
  @moduledoc false

  use GenServer

  alias Licet.Error
  alias Licet.Store
  alias Licet.Token

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: name(config.name))
  end

  @spec name(atom()) :: module()
  def name(instance), do: Module.concat(instance, Revision)

  @spec resolve(map(), term()) :: {:ok, map()} | {:error, Error.t()}
  def resolve(config, consistency) do
    cond do
      exact?(consistency) ->
        exact(config, elem(consistency, 1))

      true ->
        case open_revision(config) do
          {:ok, revision} -> {:ok, revision}
          :closed -> closed_revision(config, consistency)
          {:error, error} -> {:error, error}
        end
    end
  end

  @impl true
  def init(config) do
    case Store.current_revision(config.repo) do
      {:ok, revision} ->
        schedule(config)
        {:ok, %{config: config, revision: blank_xid(revision)}}

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, state.revision, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    state = %{state | revision: refresh(state)}
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    schedule(state.config)
    {:noreply, %{state | revision: refresh(state)}}
  end

  defp current(config) do
    GenServer.call(name(config.name), :current)
  end

  defp refresh(state) do
    case Store.current_revision(state.config.repo) do
      {:ok, revision} -> blank_xid(revision)
      {:error, _error} -> state.revision
    end
  end

  defp schedule(config) do
    Process.send_after(self(), :refresh, config.quantization)
  end

  defp fresh(config, cache?) do
    case Store.current_revision(config.repo) do
      {:ok, revision} -> {:ok, Map.merge(blank_xid(revision), %{cache?: cache?})}
      {:error, error} -> {:error, error}
    end
  end

  defp exact(config, token) do
    with {:ok, decoded} <- decode(token),
         :ok <- committed(config, decoded.xid),
         {:ok, row} <- Store.fetch_transaction(config.repo, config.prefix, decoded.xid),
         {:ok, row} <- present(row) do
      {:ok, Map.put(row, :cache?, not in_transaction?(config.repo))}
    end
  end

  defp at_least(config, token) do
    with {:ok, decoded} <- decode(token),
         :ok <- committed(config, decoded.xid),
         {:ok, revision} <- recent_enough(config, decoded.xid) do
      {:ok, Map.put(revision, :cache?, not in_transaction?(config.repo))}
    end
  end

  defp recent_enough(config, xid) do
    quantized = current(config)

    case Store.xid_visible?(config.repo, xid, quantized.snapshot) do
      {:ok, true} -> {:ok, quantized}
      {:ok, false} -> fresh_revision(config)
      {:error, error} -> {:error, error}
    end
  end

  defp fresh_revision(config) do
    case Store.current_revision(config.repo) do
      {:ok, revision} -> {:ok, blank_xid(revision)}
      {:error, error} -> {:error, error}
    end
  end

  defp committed(config, xid) do
    case Store.xact_status(config.repo, xid) do
      {:ok, "committed"} ->
        :ok

      {:ok, "in progress"} ->
        same_transaction(config, xid)

      {:ok, "aborted"} ->
        {:error, Error.new(:token_not_committed, "token transaction aborted")}

      {:ok, nil} ->
        {:error, Error.new(:snapshot_expired, "token transaction is no longer available")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp same_transaction(config, xid) do
    case Store.current_revision(config.repo) do
      {:ok, %{own_xid: ^xid}} -> :ok
      {:ok, _revision} -> {:error, Error.new(:token_not_committed, "token is not committed")}
      {:error, error} -> {:error, error}
    end
  end

  defp present(nil),
    do: {:error, Error.new(:snapshot_expired, "snapshot is outside the cleanup window")}

  defp present(row), do: {:ok, row}

  defp decode(token) do
    case Token.decode(token) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, :token_invalid} -> {:error, Error.new(:token_invalid, "token is invalid")}
    end
  end

  defp exact?({:exact, _token}), do: true
  defp exact?(_consistency), do: false

  defp blank_xid(revision), do: %{revision | own_xid: "", xid: ""}

  defp closed_revision(config, consistency) do
    cond do
      consistency in [nil, :minimize_latency] ->
        {:ok, Map.put(current(config), :cache?, true)}

      consistency == :full ->
        fresh(config, false)

      match?({:at_least, _}, consistency) ->
        at_least(config, elem(consistency, 1))

      true ->
        {:error, Error.new(:invalid_config, "unknown consistency #{inspect(consistency)}")}
    end
  end

  # An open transaction, including a shared sandbox owner, has an assigned xid
  # on the connection that actually runs the query. Autocommit checks do not.
  defp open_revision(config) do
    if in_transaction?(config.repo) or sandbox?(config.repo) do
      case Store.current_revision(config.repo) do
        {:ok, %{own_xid: ""}} -> :closed
        {:ok, revision} -> {:ok, Map.put(revision, :cache?, false)}
        {:error, error} -> {:error, error}
      end
    else
      :closed
    end
  end

  defp sandbox?(repo) do
    repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox
  end

  defp in_transaction?(repo) do
    repo
    |> Ecto.Adapter.lookup_meta()
    |> Ecto.Adapters.SQL.in_transaction?()
  end
end
