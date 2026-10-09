defmodule Licet.Testing do
  @moduledoc """
  Helpers for exercising Licet in tests.
  """

  alias Ecto.Adapters.SQL.Sandbox
  alias Licet.Migration

  @doc """
  Creates the Licet tables for `prefix` using the test repo.
  """
  @spec migrate!(module(), String.t()) :: :ok
  def migrate!(repo, prefix) when is_atom(repo) and is_binary(prefix) do
    Enum.each(Migration.statements(prefix), &repo.query!(&1, []))
  end

  @doc """
  Allows `pid` to use the sandbox connection owned by `parent`.
  """
  @spec allow(module(), pid(), pid()) :: :ok
  def allow(repo, parent, pid) do
    if repo.config()[:pool] == Sandbox do
      _ = Sandbox.allow(repo, parent, pid)
    end

    :ok
  end
end
