defmodule Licet.Sandbox do
  @moduledoc false

  alias Ecto.Adapters.SQL.Sandbox, as: SQLSandbox

  @doc """
  Lets a child process use the caller's sandbox connection.

  Does nothing when `repo` is nil or the repo is not using the SQL sandbox.
  """
  @spec allow(module() | nil, pid()) :: :ok
  def allow(nil, _parent), do: :ok

  def allow(repo, parent) do
    if repo.config()[:pool] == SQLSandbox do
      _ = SQLSandbox.allow(repo, parent, self())
    end

    :ok
  end
end
