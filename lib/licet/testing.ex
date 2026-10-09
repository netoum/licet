defmodule Licet.Testing do
  @moduledoc """
  Helpers for testing code that uses Licet.

  Licet works with `Ecto.Adapters.SQL.Sandbox`: a test's writes stay in its
  sandbox transaction and its checks see them. These helpers cover the two
  things the sandbox doesn't do on its own. See [Testing](testing.md).
  """

  alias Ecto.Adapters.SQL.Sandbox
  alias Licet.Migration

  @doc """
  Creates Licet's tables for `prefix` through `repo`.

  Run it in a test's setup to give each test its own prefix and instance.
  Inside the sandbox, the tables are rolled back with the rest of the test.

  ## Examples

      setup do
        prefix = "t\#{System.unique_integer([:positive])}"
        Licet.Testing.migrate!(MyApp.Repo, prefix)
        %{prefix: prefix}
      end
  """
  @spec migrate!(module(), String.t()) :: :ok
  def migrate!(repo, prefix) when is_atom(repo) and is_binary(prefix) do
    Enum.each(Migration.statements(prefix), &repo.query!(&1, []))
  end

  @doc """
  Lets `pid` use the sandbox connection owned by `parent`.

  Call it when a process started by the test calls Licet. Licet already does
  this for the processes it starts itself. It does nothing when `repo` doesn't
  use the sandbox pool.

  ## Examples

      test_pid = self()

      Task.async(fn ->
        Licet.Testing.allow(MyApp.Repo, test_pid, self())
        Licet.check(MyApp.Licet, "document:1", "view", "user:ada")
      end)
  """
  @spec allow(module(), pid(), pid()) :: :ok
  def allow(repo, parent, pid) do
    if repo.config()[:pool] == Sandbox do
      _ = Sandbox.allow(repo, parent, pid)
    end

    :ok
  end
end
