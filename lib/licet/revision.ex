defmodule Licet.Revision do
  @moduledoc false

  use GenServer

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
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
    if exact?(consistency) do
      exact(config, elem(consistency, 1))
    else
      case open_revision(config) do
        {:ok, revision} -> {:ok, revision}
        :closed -> closed_revision(config, consistency)
      end
    end
  end

  @impl true
  def init(config) do
    {:ok, revision} = Store.current_revision(config.repo)
    schedule(config)
    {:ok, %{config: config, revision: blank_xid(revision)}}
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
    {:ok, revision} = Store.current_revision(state.config.repo)
    blank_xid(revision)
  end

  defp schedule(config) do
    Process.send_after(self(), :refresh, config.quantization)
  end

  defp fresh(config, cache?) do
    with {:ok, revision} <- Store.current_revision(config.repo) do
      {:ok, Map.merge(blank_xid(revision), %{cache?: cache?})}
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

    with {:ok, visible} <- Store.xid_visible?(config.repo, xid, quantized.snapshot) do
      if visible, do: {:ok, quantized}, else: fresh_revision(config)
    end
  end

  defp fresh_revision(config) do
    with {:ok, revision} <- Store.current_revision(config.repo) do
      {:ok, blank_xid(revision)}
    end
  end

  defp committed(config, xid) do
    with {:ok, status} <- Store.xact_status(config.repo, xid) do
      status_result(config, xid, status)
    end
  end

  defp status_result(_config, _xid, "committed"), do: :ok
  defp status_result(config, xid, "in progress"), do: same_transaction(config, xid)

  defp status_result(_config, _xid, "aborted"),
    do: {:error, Error.new(:token_not_committed, "token transaction aborted")}

  defp status_result(_config, _xid, nil),
    do: {:error, Error.new(:snapshot_expired, "token transaction is no longer available")}

  defp same_transaction(config, xid) do
    with {:ok, revision} <- Store.current_revision(config.repo) do
      if revision.own_xid == xid do
        :ok
      else
        {:error, Error.new(:token_not_committed, "token is not committed")}
      end
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
      with {:ok, revision} <- Store.current_revision(config.repo) do
        assigned_revision(revision)
      end
    else
      :closed
    end
  end

  defp assigned_revision(%{own_xid: ""}), do: :closed
  defp assigned_revision(revision), do: {:ok, Map.put(revision, :cache?, false)}

  defp sandbox?(repo) do
    repo.config()[:pool] == Sandbox
  end

  defp in_transaction?(repo) do
    repo
    |> Ecto.Adapter.lookup_meta()
    |> SQL.in_transaction?()
  end
end
