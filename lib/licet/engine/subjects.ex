defmodule Licet.Engine.Subjects do
  @moduledoc """
  Subject-set algebra for `lookup_subjects`.

  A wildcard for a type means every id of that type except the excluded ones.
  Concrete ids are kept only when the type has no wildcard.
  """

  defstruct concrete: %{}, wildcards: %{}

  @type t :: %__MODULE__{concrete: map(), wildcards: map()}

  @doc """
  An empty subject set.
  """
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc """
  Adds one concrete subject.
  """
  @spec add(t(), String.t(), String.t()) :: t()
  def add(%__MODULE__{} = set, type, id) when is_binary(type) and is_binary(id) do
    ids = Map.get(set.concrete, type, MapSet.new())
    %{set | concrete: Map.put(set.concrete, type, MapSet.put(ids, id))}
  end

  @doc """
  Adds a wildcard for every id of `type`.
  """
  @spec allow_all(t(), String.t()) :: t()
  def allow_all(%__MODULE__{} = set, type) when is_binary(type) do
    %{
      set
      | wildcards: Map.put(set.wildcards, type, MapSet.new()),
        concrete: Map.delete(set.concrete, type)
    }
  end

  @doc """
  Union of two subject sets.
  """
  @spec union(t(), t()) :: t()
  def union(left, right), do: combine(left, right, :union)

  @doc """
  Intersection of two subject sets.
  """
  @spec intersection(t(), t()) :: t()
  def intersection(left, right), do: combine(left, right, :intersection)

  @doc """
  Subjects in `left` that are not in `right`.
  """
  @spec difference(t(), t()) :: t()
  def difference(left, right), do: combine(left, right, :difference)

  @doc """
  Number of concrete subjects plus one for each wildcard.
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{} = set) do
    concrete =
      set.concrete
      |> Map.values()
      |> Enum.reduce(0, fn ids, total -> total + MapSet.size(ids) end)

    concrete + map_size(set.wildcards)
  end

  @doc """
  Sorted `{type, id, relation}` tuples. Wildcards use id `"*"`.
  """
  @spec to_list(t()) :: [{String.t(), String.t(), String.t()}]
  def to_list(%__MODULE__{} = set) do
    wild = Enum.map(set.wildcards, fn {type, _excluded} -> {type, "*", ""} end)

    concrete =
      Enum.flat_map(set.concrete, fn {type, ids} ->
        Enum.map(ids, &{type, &1, ""})
      end)

    Enum.sort(wild ++ concrete)
  end

  defp combine(left, right, op) do
    Enum.reduce(types(left, right), empty(), fn type, acc ->
      apply_type(acc, type, left, right, op)
    end)
  end

  defp types(left, right) do
    MapSet.new(
      Map.keys(left.concrete) ++
        Map.keys(left.wildcards) ++ Map.keys(right.concrete) ++ Map.keys(right.wildcards)
    )
  end

  defp apply_type(acc, type, left, right, :union) do
    case {wild(left, type), wild(right, type)} do
      {nil, nil} -> put_ids(acc, type, MapSet.union(ids(left, type), ids(right, type)))
      {excluded, nil} -> allow_excluded(acc, type, MapSet.difference(excluded, ids(right, type)))
      {nil, excluded} -> allow_excluded(acc, type, MapSet.difference(excluded, ids(left, type)))
      {left_ex, right_ex} -> allow_excluded(acc, type, MapSet.intersection(left_ex, right_ex))
    end
  end

  defp apply_type(acc, type, left, right, :intersection) do
    case {wild(left, type), wild(right, type)} do
      {nil, nil} -> put_ids(acc, type, MapSet.intersection(ids(left, type), ids(right, type)))
      {excluded, nil} -> put_ids(acc, type, MapSet.difference(ids(right, type), excluded))
      {nil, excluded} -> put_ids(acc, type, MapSet.difference(ids(left, type), excluded))
      {left_ex, right_ex} -> allow_excluded(acc, type, MapSet.union(left_ex, right_ex))
    end
  end

  defp apply_type(acc, type, left, right, :difference) do
    case {wild(left, type), wild(right, type)} do
      {nil, nil} -> put_ids(acc, type, MapSet.difference(ids(left, type), ids(right, type)))
      {excluded, nil} -> allow_excluded(acc, type, MapSet.union(excluded, ids(right, type)))
      {nil, excluded} -> put_ids(acc, type, MapSet.intersection(ids(left, type), excluded))
      {left_ex, right_ex} -> put_ids(acc, type, MapSet.difference(right_ex, left_ex))
    end
  end

  defp put_ids(acc, type, ids) do
    if MapSet.size(ids) == 0 do
      acc
    else
      %{acc | concrete: Map.put(acc.concrete, type, ids)}
    end
  end

  defp allow_excluded(acc, type, excluded) do
    acc
    |> Map.update!(:concrete, &Map.delete(&1, type))
    |> Map.update!(:wildcards, &Map.put(&1, type, excluded))
  end

  defp ids(set, type), do: Map.get(set.concrete, type, MapSet.new())
  defp wild(set, type), do: Map.get(set.wildcards, type)
end
