defmodule Licet.Multi do
  @moduledoc """
  Adds Licet writes to an `Ecto.Multi`.

  Use it to grant access in the same transaction as the change that needs it,
  so both commit or neither does. See [Transactions](transactions.md).
  """

  @doc """
  Adds a `Licet.write/3` step named `step` to `multi`.

  The step's value is the write's token. If the write fails, the multi stops
  and `Repo.transaction/1` returns `{:error, step, %Licet.Error{}, changes_so_far}`.
  `opts` are passed to `Licet.write/3`.

  When the updates depend on an earlier step, such as the id of an inserted
  row, call `Licet.write/3` from `Ecto.Multi.run/3` instead.

  ## Examples

      Ecto.Multi.new()
      |> Ecto.Multi.update(:transfer, changeset)
      |> Licet.Multi.write(MyApp.Licet, :owner, [
        {:delete, "document:1#owner@user:ada"},
        {:create, "document:1#owner@user:bob"}
      ])
      |> MyApp.Repo.transaction()
      #=> {:ok, %{transfer: %Document{}, owner: "v1.eyJ..."}}
  """
  @spec write(Ecto.Multi.t(), Licet.instance(), Ecto.Multi.name(), [Licet.update()], keyword()) ::
          Ecto.Multi.t()
  def write(multi, name, step, updates, opts \\ []) do
    Ecto.Multi.run(multi, step, fn _repo, _changes ->
      Licet.write(name, updates, opts)
    end)
  end
end
