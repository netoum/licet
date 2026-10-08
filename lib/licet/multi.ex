defmodule Licet.Multi do
  @moduledoc """
  `Ecto.Multi` helpers that keep authorization writes in the caller's transaction.
  """

  @doc """
  Adds a Licet write step to an `Ecto.Multi`.
  """
  @spec write(Ecto.Multi.t(), atom(), atom(), list(), keyword()) :: Ecto.Multi.t()
  def write(multi, name, step, updates, opts \\ []) do
    Ecto.Multi.run(multi, step, fn _repo, _changes ->
      Licet.write(name, updates, opts)
    end)
  end
end
