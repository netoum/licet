defmodule Licet.SpiceDB do
  @moduledoc """
  A small client for SpiceDB's HTTP API, used to compare Licet with a live
  server. It speaks the JSON gateway of the `v1` API with a preshared key and
  reads every answer at full consistency.
  """

  alias Licet.Relationship

  @key "test"
  @write_chunk 1000
  @check_chunk 500
  @full %{"fullyConsistent" => true}

  @doc "The server URL, from `LICET_SPICEDB_URL`."
  @spec url() :: String.t()
  def url, do: System.get_env("LICET_SPICEDB_URL", "http://127.0.0.1:8443")

  @doc """
  Replaces the server's schema and relationships with `schema` and `relationships`.

  Relationships of the previous schema are deleted first, so the new schema
  never conflicts with stored data.
  """
  @spec load(String.t(), String.t(), [Relationship.t()]) :: :ok | {:error, term()}
  def load(url, schema, relationships) do
    with :ok <- reset(url),
         :ok <- post(url, "/v1/schema/write", %{"schema" => schema}) do
      write(url, relationships)
    end
  end

  @doc "Touches `relationships`, in chunks the server accepts."
  @spec write(String.t(), [Relationship.t()]) :: :ok | {:error, term()}
  def write(url, relationships) do
    relationships
    |> Enum.chunk_every(@write_chunk)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case post(url, "/v1/relationships/write", %{"updates" => Enum.map(chunk, &touch/1)}) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Checks every `{resource, permission, subject}` request. Objects are
  `{type, id}` and subjects `{type, id, relation}`. Answers are `{:ok, boolean}`
  or `{:error, message}`, in request order.
  """
  @spec check_bulk(String.t(), [{{String.t(), String.t()}, String.t(), tuple()}]) ::
          {:ok, [{:ok, boolean()} | {:error, String.t()}]} | {:error, term()}
  def check_bulk(url, requests) do
    requests
    |> Enum.chunk_every(@check_chunk)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      items =
        Enum.map(chunk, fn {resource, permission, subject} ->
          %{
            "resource" => object(resource),
            "permission" => permission,
            "subject" => subject(subject)
          }
        end)

      case request(url, "/v1/permissions/checkbulk", %{"consistency" => @full, "items" => items}) do
        {:ok, %{"pairs" => pairs}} -> {:cont, {:ok, acc ++ Enum.map(pairs, &pair/1)}}
        error -> {:halt, error}
      end
    end)
  end

  @doc "The ids of `type` on which `subject` has `permission`."
  @spec lookup_resources(String.t(), String.t(), String.t(), tuple()) ::
          {:ok, MapSet.t()} | {:error, term()}
  def lookup_resources(url, type, permission, subject) do
    body = %{
      "consistency" => @full,
      "resourceObjectType" => type,
      "permission" => permission,
      "subject" => subject(subject)
    }

    with {:ok, results} <- stream(url, "/v1/permissions/resources", body) do
      {:ok, MapSet.new(results, & &1["resourceObjectId"])}
    end
  end

  @doc """
  The subjects of `subject_type` (and `subject_relation`, `""` for none) that
  have `permission` on `resource`, as a map from subject id to its sorted
  excluded ids. Only a wildcard has exclusions.
  """
  @spec lookup_subjects(String.t(), {String.t(), String.t()}, String.t(), String.t(), String.t()) ::
          {:ok, %{String.t() => [String.t()]}} | {:error, term()}
  def lookup_subjects(url, resource, permission, subject_type, subject_relation) do
    body = %{
      "consistency" => @full,
      "resource" => object(resource),
      "permission" => permission,
      "subjectObjectType" => subject_type,
      "optionalSubjectRelation" => subject_relation
    }

    with {:ok, results} <- stream(url, "/v1/permissions/subjects", body) do
      {:ok,
       Map.new(results, fn result ->
         {result["subject"]["subjectObjectId"],
          result["excludedSubjects"] |> Enum.map(& &1["subjectObjectId"]) |> Enum.sort()}
       end)}
    end
  end

  defp reset(url) do
    case request(url, "/v1/schema/read", %{}) do
      {:ok, %{"schemaText" => text}} ->
        ~r/definition\s+([a-z][\w\/]*)/
        |> Regex.scan(text, capture: :all_but_first)
        |> Enum.reduce_while(:ok, fn [type], :ok -> delete_type(url, type) end)

      {:error, {404, _body}} ->
        :ok

      error ->
        error
    end
  end

  defp delete_type(url, type) do
    case post(url, "/v1/relationships/delete", %{
           "relationshipFilter" => %{"resourceType" => type}
         }) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp touch(%Relationship{} = rel) do
    relationship = %{
      "resource" => object({rel.resource_type, rel.resource_id}),
      "relation" => rel.relation,
      "subject" => subject({rel.subject_type, rel.subject_id, rel.subject_relation})
    }

    relationship =
      case rel.expires_at do
        nil -> relationship
        at -> Map.put(relationship, "optionalExpiresAt", DateTime.to_iso8601(at))
      end

    %{"operation" => "OPERATION_TOUCH", "relationship" => relationship}
  end

  defp object({type, id}), do: %{"objectType" => type, "objectId" => id}

  defp subject({type, id, relation}),
    do: %{"object" => object({type, id}), "optionalRelation" => relation}

  defp pair(%{"item" => %{"permissionship" => "PERMISSIONSHIP_HAS_PERMISSION"}}), do: {:ok, true}
  defp pair(%{"item" => %{"permissionship" => "PERMISSIONSHIP_NO_PERMISSION"}}), do: {:ok, false}
  defp pair(%{"error" => %{"message" => message}}), do: {:error, message}

  defp post(url, path, body) do
    case request(url, path, body) do
      {:ok, _body} -> :ok
      error -> error
    end
  end

  defp request(url, path, body) do
    case Req.post(url <> path, json: body, headers: headers(), retry: false) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, error} -> {:error, error}
    end
  end

  defp stream(url, path, body) do
    case Req.post(url <> path, json: body, headers: headers(), retry: false, decode_body: false) do
      {:ok, %{status: 200, body: body}} -> decode_lines(body)
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, error} -> {:error, error}
    end
  end

  defp decode_lines(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode!(line) do
        %{"result" => result} -> {:cont, {:ok, [result | acc]}}
        %{"error" => error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp headers, do: [{"authorization", "Bearer " <> @key}]
end
