defmodule Licet.Rules do
  @moduledoc false

  alias Licet.Error
  alias Licet.Relationship

  @spec relationship(map(), Relationship.t()) :: :ok | {:error, Error.t()}
  def relationship(schema, %Relationship{} = rel) do
    with {:ok, definition} <- definition(schema, rel.resource_type),
         {:ok, relation} <- relation(definition, rel),
         :ok <- subject(relation, rel) do
      expiration(schema, relation, rel)
    end
  end

  defp definition(schema, type) do
    case Map.get(schema.definitions, type) do
      nil -> {:error, Error.new(:unknown_type, "unknown type #{type}")}
      definition -> {:ok, definition}
    end
  end

  defp relation(definition, rel) do
    case Map.get(definition.relations, rel.relation) do
      nil ->
        {:error,
         Error.new(:unknown_relation, "unknown relation #{definition.name}##{rel.relation}")}

      relation ->
        {:ok, relation}
    end
  end

  defp subject(relation, rel) do
    if Enum.any?(relation.subjects, &subject_match?(&1, rel)) do
      :ok
    else
      {:error, Error.new(:invalid_relationship, "subject is not allowed by #{relation.name}")}
    end
  end

  defp subject_match?(spec, rel) do
    spec.type == rel.subject_type and form_match?(spec, rel)
  end

  defp form_match?(%{wildcard: true, relation: nil}, %{subject_id: "*", subject_relation: ""}),
    do: true

  defp form_match?(%{wildcard: false, relation: nil}, %{subject_id: id, subject_relation: ""})
       when id != "*", do: true

  defp form_match?(%{relation: relation}, %{subject_relation: relation})
       when is_binary(relation) and relation != "", do: true

  defp form_match?(_spec, _rel), do: false

  defp expiration(_schema, _relation, %{expires_at: nil}), do: :ok

  defp expiration(%{expiration: false}, _relation, _rel) do
    {:error, Error.new(:invalid_relationship, "schema does not use expiration")}
  end

  defp expiration(_schema, relation, rel) do
    if Enum.any?(relation.subjects, &(&1.expiration and subject_match?(&1, rel))) do
      :ok
    else
      {:error,
       Error.new(
         :invalid_relationship,
         "#{relation.name} does not allow expiration for this subject"
       )}
    end
  end
end
