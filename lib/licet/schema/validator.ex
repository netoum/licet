defmodule Licet.Schema.Validator do
  @moduledoc false

  alias Licet.Relationship
  alias Licet.Schema.Location

  @spec validate([term()], binary()) :: {:ok, map()} | {:error, [map()]}
  def validate(parts, source) when is_list(parts) and is_binary(source) do
    case collect(parts, source) do
      {:ok, definitions, expiration} -> compile(definitions, expiration, source)
      {:error, errors} -> {:error, errors}
    end
  end

  defp collect(parts, source) do
    {expiration, definitions, errors} =
      Enum.reduce(parts, {false, [], []}, fn part, acc -> collect_part(part, source, acc) end)

    errors = errors ++ duplicate_errors(definitions, source)

    if errors == [] do
      {:ok, definitions, expiration}
    else
      {:error, errors}
    end
  end

  defp collect_part(:use_expiration, source, {true, definitions, errors}) do
    {true, definitions, errors ++ [err(source, 0, "use expiration is repeated")]}
  end

  defp collect_part(:use_expiration, _source, {false, definitions, errors}) do
    {true, definitions, errors}
  end

  defp collect_part(%{kind: :definition} = definition, _source, {expiration, definitions, errors}) do
    {expiration, definitions ++ [definition], errors}
  end

  defp duplicate_errors(definitions, source) do
    definitions
    |> Enum.frequencies_by(& &1.name)
    |> Enum.flat_map(fn {name, count} -> duplicate_error(name, count, definitions, source) end)
  end

  defp duplicate_error(_name, count, _definitions, _source) when count < 2, do: []

  defp duplicate_error(name, _count, definitions, source) do
    definition = Enum.find(definitions, &(&1.name == name))
    [err(source, definition.offset, "definition #{name} is duplicated")]
  end

  defp compile(definitions, expiration, source) do
    errors = Enum.flat_map(definitions, &definition_errors(&1, definitions, expiration, source))

    if errors == [] do
      {:ok, schema(definitions, expiration, source)}
    else
      {:error, errors}
    end
  end

  defp definition_errors(definition, definitions, expiration, source) do
    type_error(definition, source) ++ member_errors(definition, definitions, expiration, source)
  end

  defp type_error(definition, source) do
    if valid_type?(definition) do
      []
    else
      [err(source, definition.offset, "definition #{definition.name} is not a valid type name")]
    end
  end

  defp valid_type?(definition) do
    Relationship.valid_type?(definition.name) and
      Enum.all?(definition.segments, &Relationship.valid_relation?/1)
  end

  defp member_errors(definition, definitions, expiration, source) do
    case members(definition, source) do
      {:ok, relations, permissions} ->
        relation_problems(relations, definitions, expiration, source) ++
          permission_problems(permissions, relations, definition, definitions, source)

      {:error, errors} ->
        errors
    end
  end

  defp members(definition, source) do
    Enum.reduce_while(definition.members, {:ok, %{}, %{}}, fn member,
                                                              {:ok, relations, permissions} ->
      accept_member(member, definition, source, relations, permissions)
    end)
  end

  defp accept_member(
         %{kind: :permission} = permission,
         definition,
         source,
         relations,
         permissions
       ) do
    if taken?(permission.name, relations, permissions) do
      {:halt,
       {:error,
        [err(source, permission.offset, "#{definition.name}.#{permission.name} is duplicated")]}}
    else
      {:cont, {:ok, relations, Map.put(permissions, permission.name, permission)}}
    end
  end

  defp accept_member(relation, definition, source, relations, permissions) do
    if taken?(relation.name, relations, permissions) do
      {:halt,
       {:error,
        [err(source, relation.offset, "#{definition.name}.#{relation.name} is duplicated")]}}
    else
      {:cont, {:ok, Map.put(relations, relation.name, relation), permissions}}
    end
  end

  defp taken?(name, relations, permissions) do
    Map.has_key?(relations, name) or Map.has_key?(permissions, name)
  end

  defp relation_problems(relations, definitions, expiration, source) do
    Enum.flat_map(relations, fn {_name, relation} ->
      relation_name_error(relation, source) ++
        Enum.flat_map(
          relation.subjects,
          &subject_errors(&1, relation, definitions, expiration, source)
        )
    end)
  end

  defp relation_name_error(relation, source) do
    if Relationship.valid_relation?(relation.name) do
      []
    else
      [err(source, relation.offset, "relation #{relation.name} is not a valid name")]
    end
  end

  defp subject_errors(subject, relation, definitions, expiration, source) do
    subject_type_error(subject, definitions, source) ++
      subject_relation_error(subject, source) ++
      expiration_error(subject, relation, expiration, source)
  end

  defp subject_type_error(subject, definitions, source) do
    cond do
      definition_named(definitions, subject.type) == nil ->
        [err(source, subject.offset, "unknown type #{subject.type}")]

      not Relationship.valid_type?(subject.type) ->
        [err(source, subject.offset, "type #{subject.type} is not a valid name")]

      true ->
        []
    end
  end

  defp subject_relation_error(%{relation: nil}, _source), do: []

  defp subject_relation_error(subject, source) do
    if Relationship.valid_relation?(subject.relation) do
      []
    else
      [err(source, subject.offset, "subject relation #{subject.relation} is not a valid name")]
    end
  end

  defp expiration_error(%{expiration: false}, _relation, _enabled, _source), do: []
  defp expiration_error(_subject, _relation, true, _source), do: []

  defp expiration_error(subject, relation, false, source) do
    [err(source, subject.offset, "#{relation.name} uses expiration without use expiration")]
  end

  defp permission_problems(permissions, relations, definition, definitions, source) do
    Enum.flat_map(permissions, fn {_name, permission} ->
      permission_name_error(permission, source) ++
        expr_errors(
          permission.expr,
          relations,
          permissions,
          definition,
          definitions,
          source,
          MapSet.new([{definition.name, permission.name}]),
          false
        )
    end)
  end

  defp permission_name_error(permission, source) do
    if Relationship.valid_relation?(permission.name) do
      []
    else
      [err(source, permission.offset, "permission #{permission.name} is not a valid name")]
    end
  end

  defp expr_errors(
         {:name, name, offset},
         relations,
         permissions,
         definition,
         definitions,
         source,
         stack,
         hop
       ) do
    frame = {definition.name, name}

    cond do
      Map.has_key?(relations, name) ->
        []

      MapSet.member?(stack, frame) and hop ->
        []

      MapSet.member?(stack, frame) ->
        [err(source, offset, "permission cycle at #{definition.name}.#{name}")]

      Map.has_key?(permissions, name) ->
        nested = Map.fetch!(permissions, name)

        expr_errors(
          nested.expr,
          relations,
          permissions,
          definition,
          definitions,
          source,
          MapSet.put(stack, frame),
          false
        )

      true ->
        [err(source, offset, "unknown relation or permission #{name}")]
    end
  end

  defp expr_errors(
         {:union, left, right},
         relations,
         permissions,
         definition,
         definitions,
         source,
         stack,
         hop
       ) do
    expr_errors(left, relations, permissions, definition, definitions, source, stack, hop) ++
      expr_errors(right, relations, permissions, definition, definitions, source, stack, hop)
  end

  defp expr_errors(
         {:intersection, left, right},
         relations,
         permissions,
         definition,
         definitions,
         source,
         stack,
         hop
       ) do
    expr_errors(left, relations, permissions, definition, definitions, source, stack, hop) ++
      expr_errors(right, relations, permissions, definition, definitions, source, stack, hop)
  end

  defp expr_errors(
         {:exclusion, left, right},
         relations,
         permissions,
         definition,
         definitions,
         source,
         stack,
         hop
       ) do
    expr_errors(left, relations, permissions, definition, definitions, source, stack, hop) ++
      expr_errors(right, relations, permissions, definition, definitions, source, stack, hop)
  end

  defp expr_errors(
         {:arrow, left, right},
         relations,
         permissions,
         definition,
         definitions,
         source,
         stack,
         _hop
       ) do
    arrow_errors(left, right, relations, permissions, definition, definitions, source, stack)
  end

  defp arrow_errors(left, right, relations, permissions, definition, definitions, source, stack) do
    case subject_definitions(left, relations, permissions, definition, definitions, source, stack) do
      {:ok, targets} ->
        Enum.flat_map(targets, fn target ->
          {target_relations, target_permissions} = split_compiled_pending(target)

          expr_errors(
            right,
            target_relations,
            target_permissions,
            target,
            definitions,
            source,
            stack,
            true
          )
        end)

      {:error, errors} ->
        errors
    end
  end

  defp subject_definitions(
         {:name, name, offset},
         relations,
         _permissions,
         _definition,
         definitions,
         source,
         _stack
       ) do
    case Map.get(relations, name) do
      nil ->
        {:error, [err(source, offset, "arrow #{name} must start from a relation")]}

      relation ->
        {:ok, known_targets(relation, definitions)}
    end
  end

  defp subject_definitions(
         {:arrow, inner, {:name, name, offset}},
         relations,
         permissions,
         definition,
         definitions,
         source,
         stack
       ) do
    case subject_definitions(
           inner,
           relations,
           permissions,
           definition,
           definitions,
           source,
           stack
         ) do
      {:ok, targets} -> relation_subjects(targets, name, offset, definitions, source)
      {:error, errors} -> {:error, errors}
    end
  end

  defp subject_definitions(
         _left,
         _relations,
         _permissions,
         _definition,
         _definitions,
         source,
         _stack
       ) do
    {:error, [err(source, 0, "arrow must start from a relation")]}
  end

  defp known_targets(relation, definitions) do
    relation.subjects
    |> Enum.map(&definition_named(definitions, &1.type))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.name)
  end

  defp relation_subjects(targets, name, offset, definitions, source) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, acc} ->
      relation = raw_relation(target, name)

      if relation do
        {:cont, {:ok, acc ++ known_targets(relation, definitions)}}
      else
        message = "arrow #{name} must be a relation on #{target.name}"
        {:halt, {:error, [err(source, offset, message)]}}
      end
    end)
  end

  defp raw_relation(%{members: members}, name) do
    Enum.find(members, fn
      %{kind: :permission} -> false
      relation -> relation.name == name
    end)
  end

  defp split_compiled_pending(definition) do
    relations =
      Map.new(definition.members, fn
        %{kind: :permission} -> {nil, nil}
        relation -> {relation.name, relation}
      end)
      |> Map.delete(nil)

    permissions =
      Map.new(definition.members, fn
        %{kind: :permission} = permission -> {permission.name, permission}
        _relation -> {nil, nil}
      end)
      |> Map.delete(nil)

    {relations, permissions}
  end

  defp definition_named(definitions, name) do
    Enum.find(definitions, &(&1.name == name))
  end

  defp schema(definitions, expiration, source) do
    Licet.Schema.Compiler.compile(definitions, expiration, source)
  end

  defp err(source, offset, message) do
    {line, column} = Location.line_col(source, offset)
    %{reason: :invalid_schema, message: message, line: line, column: column}
  end
end
