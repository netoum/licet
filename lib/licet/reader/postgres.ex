defmodule Licet.Reader.Postgres do
  @moduledoc """
  Relationship reader that queries the Licet tables in Postgres.
  """

  defstruct [:repo, :prefix]

  @type t :: %__MODULE__{repo: module(), prefix: String.t()}

  defimpl Licet.Reader do
    def list(%{repo: repo, prefix: prefix}, filter) do
      Licet.Store.list_relationships(repo, prefix, filter)
    end
  end
end
