defmodule Licet.Engine.Subjects do
  @moduledoc """
  Subject-set algebra for `lookup_subjects`, the same as SpiceDB's subject sets
  without caveats.

  Subjects are grouped by `{type, relation}`, with `""` for no relation, so
  usersets such as `team:eng#member` are subjects too. Within a group a
  wildcard means every id except its excluded ones, and concrete ids are kept
  next to it: a union of `user:*` and `user:tom` holds both, and removing
  `user:dan` from `user:*` records `user:dan` as excluded.
  """

  defstruct sets: %{}

  @type key :: {String.t(), String.t()}
  @type group :: %{concrete: MapSet.t(String.t()), wildcard: MapSet.t(String.t()) | nil}
  @type t :: %__MODULE__{sets: %{optional(key()) => group()}}
  @type found :: %{subject: {String.t(), String.t(), String.t()}, excluded: [String.t()]}

  @doc """
  An empty subject set.
  """
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc """
  Adds one subject. Id `"*"` adds a wildcard for every id of `type`.
  """
  @spec add(t(), String.t(), String.t(), String.t()) :: t()
  def add(%__MODULE__{} = set, type, id, relation \\ "")
      when is_binary(type) and is_binary(id) and is_binary(relation) do
    put(set, {type, relation}, add_id(get(set, {type, relation}), id))
  end

  @doc """
  Union of two subject sets.
  """
  @spec union(t(), t()) :: t()
  def union(%__MODULE__{} = left, %__MODULE__{} = right) do
    Enum.reduce(right.sets, left, fn {key, group}, acc ->
      put(acc, key, union_group(get(acc, key), group))
    end)
  end

  @doc """
  Intersection of two subject sets.
  """
  @spec intersection(t(), t()) :: t()
  def intersection(%__MODULE__{} = left, %__MODULE__{} = right) do
    sets =
      for {key, group} <- left.sets, Map.has_key?(right.sets, key), into: %{} do
        {key, intersect_group(group, Map.fetch!(right.sets, key))}
      end

    prune(%__MODULE__{sets: sets})
  end

  @doc """
  Subjects in `left` that are not in `right`.
  """
  @spec difference(t(), t()) :: t()
  def difference(%__MODULE__{} = left, %__MODULE__{} = right) do
    sets =
      Map.new(left.sets, fn {key, group} ->
        case Map.fetch(right.sets, key) do
          {:ok, other} -> {key, subtract_group(group, other)}
          :error -> {key, group}
        end
      end)

    prune(%__MODULE__{sets: sets})
  end

  @doc """
  Keeps only subjects of `type` with `relation`.
  """
  @spec only(t(), String.t(), String.t()) :: t()
  def only(%__MODULE__{} = set, type, relation) do
    %__MODULE__{sets: Map.take(set.sets, [{type, relation}])}
  end

  @doc """
  Number of concrete subjects plus one for each wildcard.
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{} = set) do
    Enum.reduce(set.sets, 0, fn {_key, group}, total ->
      total + MapSet.size(group.concrete) + if(group.wildcard, do: 1, else: 0)
    end)
  end

  @doc """
  Subjects sorted by `{type, id, relation}`. A wildcard has id `"*"` and lists
  its sorted excluded ids; concrete subjects exclude nothing.
  """
  @spec to_list(t()) :: [found()]
  def to_list(%__MODULE__{} = set) do
    set.sets
    |> Enum.flat_map(fn {{type, relation}, group} ->
      concrete = Enum.map(group.concrete, &%{subject: {type, &1, relation}, excluded: []})

      case group.wildcard do
        nil -> concrete
        excluded -> [%{subject: {type, "*", relation}, excluded: Enum.sort(excluded)} | concrete]
      end
    end)
    |> Enum.sort_by(& &1.subject)
  end

  defp get(set, key), do: Map.get(set.sets, key, %{concrete: MapSet.new(), wildcard: nil})
  defp put(set, key, group), do: %{set | sets: Map.put(set.sets, key, group)}

  defp prune(set) do
    %{set | sets: Map.reject(set.sets, fn {_key, group} -> empty_group?(group) end)}
  end

  defp empty_group?(group), do: group.wildcard == nil and MapSet.size(group.concrete) == 0

  defp add_id(group, "*"), do: add_wildcard(group, MapSet.new())

  defp add_id(group, id) do
    %{concrete: MapSet.put(group.concrete, id), wildcard: drop_excluded(group.wildcard, [id])}
  end

  defp add_wildcard(group, excluded) do
    merged =
      case group.wildcard do
        nil -> excluded
        existing -> MapSet.intersection(existing, excluded)
      end

    %{group | wildcard: drop_excluded(merged, group.concrete)}
  end

  defp drop_excluded(nil, _ids), do: nil
  defp drop_excluded(excluded, ids), do: MapSet.difference(excluded, MapSet.new(ids))

  defp union_group(group, other) do
    group = Enum.reduce(other.concrete, group, &add_id(&2, &1))

    case other.wildcard do
      nil -> group
      excluded -> add_wildcard(group, excluded)
    end
  end

  defp subtract_group(group, other) do
    wildcard =
      case group.wildcard do
        nil -> nil
        excluded -> MapSet.union(excluded, other.concrete)
      end

    group = %{concrete: MapSet.difference(group.concrete, other.concrete), wildcard: wildcard}

    case other.wildcard do
      nil -> group
      removing -> subtract_wildcard(group, removing)
    end
  end

  defp subtract_wildcard(group, removing) do
    kept = MapSet.intersection(group.concrete, removing)
    %{concrete: uncovered(kept, group.wildcard, removing), wildcard: nil}
  end

  defp uncovered(kept, nil, _removing), do: kept

  defp uncovered(kept, excluded, removing),
    do: MapSet.union(kept, MapSet.difference(removing, excluded))

  defp intersect_group(group, other) do
    concrete =
      MapSet.union(
        MapSet.filter(group.concrete, &member?(other, &1)),
        MapSet.filter(other.concrete, &member?(group, &1))
      )

    wildcard =
      case {group.wildcard, other.wildcard} do
        {nil, _} -> nil
        {_, nil} -> nil
        {left, right} -> MapSet.union(left, right)
      end

    %{concrete: concrete, wildcard: wildcard}
  end

  defp member?(group, id) do
    MapSet.member?(group.concrete, id) or
      (group.wildcard != nil and not MapSet.member?(group.wildcard, id))
  end
end
