defmodule Licet.Engine.Membership do
  # Subjects found by a recursive expand, each with the relations that hold it.
  #
  # This is the set behind expected relations in a validation file, the same
  # bookkeeping as SpiceDB's developer membership set without caveats. It is the
  # algebra of `Licet.Engine.Subjects`, plus the relations that hold each
  # subject: usersets such as `team:eng#member` are subjects too, and a wildcard
  # and concrete ids of the same type are kept side by side.
  #
  # Subjects are `{type, id, relation}` tuples, with `""` for no relation.
  @moduledoc false

  defstruct sets: %{}

  @type onr :: {String.t(), String.t(), String.t()}
  @type found :: %{subject: onr(), excluded: [onr()], resources: [onr()]}
  @type t :: %__MODULE__{sets: %{optional({String.t(), String.t()}) => map()}}

  @doc """
  An empty set.
  """
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc """
  The subjects written directly on `resource`, each held by `resource`.
  """
  @spec leaf([onr()], onr()) :: t()
  def leaf(subjects, resource) do
    held = MapSet.new([resource])

    Enum.reduce(subjects, empty(), fn {type, id, relation}, acc ->
      put_set(acc, {type, relation}, add(get_set(acc, {type, relation}), id, held))
    end)
  end

  @doc """
  Every subject in either set.
  """
  @spec union(t(), t()) :: t()
  def union(%__MODULE__{} = left, %__MODULE__{} = right) do
    Enum.reduce(right.sets, left, fn {key, set}, acc ->
      put_set(acc, key, union_set(get_set(acc, key), set))
    end)
  end

  @doc """
  Subjects in both sets. The relations that hold a subject on either side are kept.
  """
  @spec intersection(t(), t()) :: t()
  def intersection(%__MODULE__{} = left, %__MODULE__{} = right) do
    sets =
      for {key, set} <- left.sets, Map.has_key?(right.sets, key), into: %{} do
        {key, intersect_set(set, Map.fetch!(right.sets, key))}
      end

    %__MODULE__{sets: sets}
  end

  @doc """
  Subjects in `left` that are not in `right`.
  """
  @spec difference(t(), t()) :: t()
  def difference(%__MODULE__{} = left, %__MODULE__{} = right) do
    sets =
      Map.new(left.sets, fn {key, set} ->
        case Map.fetch(right.sets, key) do
          {:ok, other} -> {key, subtract_set(set, other)}
          :error -> {key, set}
        end
      end)

    %__MODULE__{sets: sets}
  end

  @doc """
  Found subjects sorted by subject, with sorted exclusions and resources.
  """
  @spec to_list(t()) :: [found()]
  def to_list(%__MODULE__{} = membership) do
    membership.sets
    |> Enum.flat_map(fn {{type, relation}, set} -> found(type, relation, set) end)
    |> Enum.sort_by(& &1.subject)
  end

  defp found(type, relation, set) do
    concrete =
      Enum.map(set.concrete, fn {id, resources} ->
        %{subject: {type, id, relation}, excluded: [], resources: Enum.sort(resources)}
      end)

    concrete ++ wildcard_found(type, relation, set.wildcard)
  end

  defp wildcard_found(_type, _relation, nil), do: []

  defp wildcard_found(type, relation, wildcard) do
    excluded = wildcard.excluded |> Map.keys() |> Enum.sort() |> Enum.map(&{type, &1, relation})

    [
      %{
        subject: {type, "*", relation},
        excluded: excluded,
        resources: Enum.sort(wildcard.resources)
      }
    ]
  end

  defp get_set(membership, key),
    do: Map.get(membership.sets, key, %{concrete: %{}, wildcard: nil})

  defp put_set(membership, key, set), do: %{membership | sets: Map.put(membership.sets, key, set)}

  defp add(set, "*", resources), do: add_wildcard(set, %{resources: resources, excluded: %{}})
  defp add(set, id, resources), do: add_concrete(set, id, resources)

  defp add_concrete(set, id, resources) do
    %{
      concrete: Map.update(set.concrete, id, resources, &MapSet.union(&1, resources)),
      wildcard: drop_exclusions(set.wildcard, [id])
    }
  end

  defp add_wildcard(set, wildcard) do
    merged =
      case set.wildcard do
        nil ->
          wildcard

        existing ->
          %{
            resources: MapSet.union(existing.resources, wildcard.resources),
            excluded: intersect_held(existing.excluded, wildcard.excluded)
          }
      end

    %{set | wildcard: drop_exclusions(merged, Map.keys(set.concrete))}
  end

  defp drop_exclusions(nil, _ids), do: nil

  defp drop_exclusions(wildcard, ids),
    do: %{wildcard | excluded: Map.drop(wildcard.excluded, ids)}

  defp union_set(set, other) do
    set = Enum.reduce(other.concrete, set, fn {id, held}, acc -> add_concrete(acc, id, held) end)

    case other.wildcard do
      nil -> set
      wildcard -> add_wildcard(set, wildcard)
    end
  end

  defp subtract_set(set, other) do
    set =
      Enum.reduce(other.concrete, set, fn {id, held}, acc -> subtract_concrete(acc, id, held) end)

    case other.wildcard do
      nil -> set
      wildcard -> subtract_wildcard(set, wildcard)
    end
  end

  defp subtract_concrete(set, id, resources) do
    wildcard =
      case set.wildcard do
        nil ->
          nil

        wildcard ->
          excluded = Map.update(wildcard.excluded, id, resources, &MapSet.union(&1, resources))
          %{wildcard | excluded: excluded}
      end

    %{concrete: Map.delete(set.concrete, id), wildcard: wildcard}
  end

  defp subtract_wildcard(set, removing) do
    kept = Map.take(set.concrete, Map.keys(removing.excluded))
    %{concrete: Map.merge(kept, uncovered(set.wildcard, removing)), wildcard: nil}
  end

  defp uncovered(nil, _removing), do: %{}

  defp uncovered(wildcard, removing) do
    Map.reject(removing.excluded, fn {id, _held} -> Map.has_key?(wildcard.excluded, id) end)
  end

  defp intersect_set(set, other) do
    concrete =
      Enum.reduce(set.concrete, %{}, fn {id, held}, acc ->
        in_both = other.concrete |> Map.get(id) |> held_union_if(held)
        put_held(acc, id, held_union(in_both, allowed_by(other.wildcard, id, held)))
      end)

    concrete =
      Enum.reduce(other.concrete, concrete, fn {id, held}, acc ->
        put_held(acc, id, held_union(Map.get(acc, id), allowed_by(set.wildcard, id, held)))
      end)

    %{concrete: concrete, wildcard: intersect_wildcards(set.wildcard, other.wildcard)}
  end

  defp intersect_wildcards(nil, _other), do: nil
  defp intersect_wildcards(_wildcard, nil), do: nil

  defp intersect_wildcards(left, right) do
    %{
      resources: MapSet.union(left.resources, right.resources),
      excluded: Map.merge(left.excluded, right.excluded, fn _id, a, b -> MapSet.union(a, b) end)
    }
  end

  defp allowed_by(nil, _id, _held), do: nil

  defp allowed_by(wildcard, id, held) do
    if Map.has_key?(wildcard.excluded, id), do: nil, else: held
  end

  defp intersect_held(left, right) do
    for {id, held} <- left, Map.has_key?(right, id), into: %{} do
      {id, MapSet.union(held, Map.fetch!(right, id))}
    end
  end

  defp held_union_if(nil, _held), do: nil
  defp held_union_if(other, held), do: MapSet.union(held, other)

  defp held_union(nil, other), do: other
  defp held_union(held, nil), do: held
  defp held_union(held, other), do: MapSet.union(held, other)

  defp put_held(acc, _id, nil), do: acc
  defp put_held(acc, id, held), do: Map.put(acc, id, held)
end
