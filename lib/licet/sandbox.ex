defmodule Licet.Sandbox do
  @moduledoc false

  @doc """
  Lets a child process use the caller's sandbox connection.

  Does nothing when `repo` is nil or the repo is not using the SQL sandbox.
  """
  @spec allow(module() | nil, pid()) :: :ok
  def allow(nil, _parent), do: :ok

  def allow(repo, parent) do
    if repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      _ = Ecto.Adapters.SQL.Sandbox.allow(repo, parent, self())
    end

    :ok
  end
end
