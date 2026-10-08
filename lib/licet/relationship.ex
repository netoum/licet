defmodule Licet.Relationship do
  @moduledoc """
  One relationship tuple.

  Text form follows SpiceDB: `document:roadmap#owner@user:anne`,
  `document:roadmap#viewer@team:eng#member`, and
  `document:roadmap#viewer@user:anne[expiration:2026-01-01T00:00:00Z]`.
  Names stay strings. Licet never turns them into atoms.
  """

  defstruct [
    :resource_type,
    :resource_id,
    :relation,
    :subject_type,
    :subject_id,
    :subject_relation,
    :expires_at
  ]

  @type t :: %__MODULE__{
          resource_type: String.t(),
          resource_id: String.t(),
          relation: String.t(),
          subject_type: String.t(),
          subject_id: String.t(),
          subject_relation: String.t(),
          expires_at: DateTime.t() | nil
        }

  @type_segment ~r/^[a-z][a-z0-9_]{1,62}[a-z0-9]$/
  @object_id ~r/^[A-Za-z0-9\/_|=\-+]{1,1024}$/
  @relation ~r/^[a-z][a-z0-9_]{1,62}[a-z0-9]$/

  @doc """
  Parses a relationship string.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, Licet.Error.t()}
  def parse(value) when is_binary(value) do
    with {:ok, body, expires} <- split_expiration(value),
         {:ok, resource, relation, subject} <- split_body(body),
         {:ok, resource_type, resource_id} <- split_ref(resource),
         {:ok, subject_type, subject_id, subject_relation} <- split_subject(subject),
         :ok <- validate_type(resource_type),
         :ok <- validate_id(resource_id),
         :ok <- validate_relation(relation),
         :ok <- validate_type(subject_type),
         :ok <- validate_subject_id(subject_id),
         :ok <- validate_optional_relation(subject_relation),
         {:ok, expires_at} <- parse_expiration(expires) do
      {:ok,
       %__MODULE__{
         resource_type: resource_type,
         resource_id: resource_id,
         relation: relation,
         subject_type: subject_type,
         subject_id: subject_id,
         subject_relation: subject_relation || "",
         expires_at: expires_at
       }}
    else
      {:error, %Licet.Error{} = error} -> {:error, error}
      :error -> {:error, invalid("relationship #{inspect(value)} is not valid")}
    end
  end

  def parse(other) do
    {:error, invalid("relationship must be a string, got #{inspect(other)}")}
  end

  @doc """
  Renders a relationship in SpiceDB text form.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = rel) do
    base =
      rel.resource_type <>
        ":" <>
        rel.resource_id <>
        "#" <>
        rel.relation <> "@" <> rel.subject_type <> ":" <> rel.subject_id

    base = append_subject_relation(base, rel.subject_relation)
    append_expiration(base, rel.expires_at)
  end

  @doc """
  Parses `document:1` or `team:eng#member`.
  """
  @spec parse_object(String.t()) ::
          {:ok, String.t(), String.t(), String.t()} | {:error, Licet.Error.t()}
  def parse_object(value) when is_binary(value) do
    case String.split(value, "#", parts: 2) do
      [ref, relation] -> object_with_relation(ref, relation)
      [ref] -> object_without_relation(ref)
    end
  end

  def parse_object(other) do
    {:error, invalid("object must be a string, got #{inspect(other)}")}
  end

  @doc false
  @spec valid_type?(String.t()) :: boolean()
  def valid_type?(value) when is_binary(value) and byte_size(value) <= 128 do
    value |> String.split("/") |> Enum.all?(&Regex.match?(@type_segment, &1))
  end

  def valid_type?(_value), do: false

  @doc false
  @spec valid_relation?(String.t()) :: boolean()
  def valid_relation?(value), do: is_binary(value) and Regex.match?(@relation, value)

  @doc false
  @spec valid_id?(String.t()) :: boolean()
  def valid_id?(value), do: is_binary(value) and Regex.match?(@object_id, value)

  defp split_expiration(value) do
    case String.split(value, "[expiration:", parts: 2) do
      [body, rest] ->
        if String.ends_with?(rest, "]") do
          {:ok, body, String.trim_trailing(rest, "]")}
        else
          :error
        end

      [body] ->
        {:ok, body, nil}
    end
  end

  defp split_body(body) do
    case String.split(body, "#", parts: 2) do
      [resource, relation_and_subject] ->
        case String.split(relation_and_subject, "@", parts: 2) do
          [relation, subject] -> {:ok, resource, relation, subject}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp split_ref(value) do
    case String.split(value, ":", parts: 2) do
      [type, id] when type != "" and id != "" -> {:ok, type, id}
      _ -> :error
    end
  end

  defp split_subject(value) do
    case String.split(value, "#", parts: 2) do
      [ref, relation] ->
        case split_ref(ref) do
          {:ok, type, id} -> {:ok, type, id, relation}
          :error -> :error
        end

      [ref] ->
        case split_ref(ref) do
          {:ok, type, id} -> {:ok, type, id, nil}
          :error -> :error
        end
    end
  end

  defp validate_type(type) do
    if valid_type?(type), do: :ok, else: :error
  end

  defp validate_id(id) do
    if valid_id?(id), do: :ok, else: :error
  end

  defp validate_subject_id("*"), do: :ok
  defp validate_subject_id(id), do: validate_id(id)

  defp validate_relation(relation) do
    if valid_relation?(relation), do: :ok, else: :error
  end

  defp validate_optional_relation(nil), do: :ok

  defp validate_optional_relation(relation) do
    if valid_relation?(relation), do: :ok, else: :error
  end

  defp parse_expiration(nil), do: {:ok, nil}

  defp parse_expiration(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
      {:error, _reason} -> {:error, invalid("expiration #{inspect(value)} is not RFC3339")}
    end
  end

  defp append_subject_relation(base, relation) when relation in [nil, ""], do: base
  defp append_subject_relation(base, relation), do: base <> "#" <> relation

  defp append_expiration(base, nil), do: base

  defp append_expiration(base, %DateTime{} = datetime) do
    base <> "[expiration:" <> DateTime.to_iso8601(datetime) <> "]"
  end

  defp object_with_relation(ref, relation) do
    with {:ok, type, id} <- object_ref(ref),
         true <- valid_relation?(relation) do
      {:ok, type, id, relation}
    else
      _ -> {:error, invalid("object #{inspect(ref <> "#" <> relation)} is not valid")}
    end
  end

  defp object_without_relation(ref) do
    case object_ref(ref) do
      {:ok, type, id} -> {:ok, type, id, ""}
      :error -> {:error, invalid("object #{inspect(ref)} is not valid")}
    end
  end

  defp object_ref(value) do
    case String.split(value, ":", parts: 2) do
      [type, "*"] -> if(valid_type?(type), do: {:ok, type, "*"}, else: :error)
      [type, id] -> if(valid_type?(type) and valid_id?(id), do: {:ok, type, id}, else: :error)
      _ -> :error
    end
  end

  defp invalid(message), do: Licet.Error.new(:invalid_relationship, message)
end
