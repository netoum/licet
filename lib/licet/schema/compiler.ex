defmodule Licet.Schema.Compiler do
  @moduledoc false

  @spec compile([map()], boolean(), binary()) :: map()
  def compile(definitions, expiration, source) do
    compiled = Map.new(definitions, &{&1.name, compile_definition(&1)})

    %{
      definitions: compiled,
      expiration: expiration,
      source: source,
      hash: hash(source)
    }
  end

  defp compile_definition(definition) do
    {relations, permissions} = split(definition)

    %{
      name: definition.name,
      relations:
        Map.new(relations, fn {name, relation} -> {name, compile_relation(relation)} end),
      permissions:
        Map.new(permissions, fn {name, permission} -> {name, compile_expr(permission.expr)} end)
    }
  end

  defp split(definition) do
    Enum.reduce(definition.members, {%{}, %{}}, fn
      %{kind: :permission} = permission, {relations, permissions} ->
        {relations, Map.put(permissions, permission.name, permission)}

      relation, {relations, permissions} ->
        {Map.put(relations, relation.name, relation), permissions}
    end)
  end

  defp compile_relation(relation) do
    %{
      name: relation.name,
      subjects:
        Enum.map(relation.subjects, fn subject ->
          %{
            type: subject.type,
            wildcard: subject.wildcard,
            relation: subject.relation,
            expiration: subject.expiration
          }
        end)
    }
  end

  defp compile_expr({:name, name, _offset}), do: {:ref, name}
  defp compile_expr({:nil_expr, _offset}), do: :nil_expr
  defp compile_expr({:union, left, right}), do: {:union, compile_expr(left), compile_expr(right)}

  defp compile_expr({:intersection, left, right}),
    do: {:intersection, compile_expr(left), compile_expr(right)}

  defp compile_expr({:exclusion, left, right}),
    do: {:exclusion, compile_expr(left), compile_expr(right)}

  defp compile_expr({kind, {:name, name, _offset}, right}) when kind in [:arrow, :arrow_all] do
    {kind, name, compile_expr(right)}
  end

  defp compile_expr({kind, left, right}) when kind in [:arrow, :arrow_all] do
    {kind, compile_expr(left), compile_expr(right)}
  end

  defp hash(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end
end
