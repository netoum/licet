defmodule Licet.Schema.Diff do
  @moduledoc """
  Compares two compiled schemas and reports changes that can strand data.
  """

  @type change :: %{
          removed_definitions: [String.t()],
          removed_relations: [{String.t(), String.t()}],
          dropped_expiration: boolean(),
          narrowed: [{String.t(), String.t()}]
        }

  @doc """
  Returns the unsafe-shaped changes between two schemas.

  `old` may be nil when the database has no schema yet.
  """
  @spec changes(map() | nil, map()) :: change()
  def changes(nil, _new) do
    %{removed_definitions: [], removed_relations: [], dropped_expiration: false, narrowed: []}
  end

  def changes(old, new) do
    %{
      removed_definitions: removed_definitions(old, new),
      removed_relations: removed_relations(old, new),
      dropped_expiration: old.expiration and not new.expiration,
      narrowed: narrowed(old, new)
    }
  end

  @doc """
  Relations whose allowed subject types shrank, including removed relations.
  """
  @spec narrowed(map(), map()) :: [{String.t(), String.t()}]
  def narrowed(old, new) do
    Enum.flat_map(old.definitions, fn {type, definition} ->
      narrowed_relations(type, definition, Map.get(new.definitions, type))
    end)
  end

  defp removed_definitions(old, new) do
    old.definitions
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(new.definitions, &1))
    |> Enum.sort()
  end

  defp removed_relations(old, new) do
    Enum.flat_map(old.definitions, fn {type, definition} ->
      case Map.get(new.definitions, type) do
        nil ->
          []

        newer ->
          definition.relations
          |> Map.keys()
          |> Enum.reject(&Map.has_key?(newer.relations, &1))
          |> Enum.map(&{type, &1})
      end
    end)
  end

  defp narrowed_relations(_type, _definition, nil), do: []

  defp narrowed_relations(type, definition, newer) do
    Enum.flat_map(definition.relations, fn {name, relation} ->
      narrowed_name(type, name, relation, Map.get(newer.relations, name))
    end)
  end

  defp narrowed_name(_type, _name, _relation, nil), do: []

  defp narrowed_name(type, name, relation, next) do
    if subjects_narrowed?(relation, next), do: [{type, name}], else: []
  end

  defp subjects_narrowed?(relation, next) do
    old = MapSet.new(relation.subjects, &subject_key/1)
    new = MapSet.new(next.subjects, &subject_key/1)
    not MapSet.subset?(old, new)
  end

  defp subject_key(subject) do
    {subject.type, subject.wildcard, subject.relation}
  end
end
