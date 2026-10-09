defmodule Licet.Reader.Memory do
  # Relationship reader backed by a list of tuples.
  @moduledoc false

  defstruct tuples: []

  @type t :: %__MODULE__{tuples: [Licet.Relationship.t()]}

  defimpl Licet.Reader do
    def list(%{tuples: tuples}, filter) do
      at = Map.fetch!(filter, :at)
      Enum.filter(tuples, &visible?(&1, filter, at))
    end

    defp visible?(tuple, filter, at) do
      current?(tuple, at) and equals?(tuple, filter)
    end

    defp current?(%{expires_at: nil}, _at), do: true
    defp current?(%{expires_at: expires_at}, at), do: DateTime.compare(expires_at, at) == :gt

    defp equals?(tuple, filter) do
      Enum.all?(
        [:resource_type, :resource_id, :relation, :subject_type, :subject_id, :subject_relation],
        fn field ->
          case Map.get(filter, field) do
            nil -> true
            value -> Map.get(tuple, field) == value
          end
        end
      )
    end
  end
end
