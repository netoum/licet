defmodule Licet.Differential do
  @moduledoc false

  def maybe do
    if System.get_env("LICET_SPICEDB") == "1" do
      compare()
    else
      :skipped
    end
  end

  defp compare do
    Application.ensure_all_started(:req)
    count = System.get_env("LICET_DIFFERENTIAL_CASES", "100") |> String.to_integer()
    url = System.get_env("LICET_SPICEDB_URL", "http://127.0.0.1:8443")
    schema = schema()

    with {:ok, compiled} <- Licet.Schema.parse(schema),
         :ok <- spice_schema(url, schema) do
      run_cases(url, compiled, count)
    end
  end

  defp run_cases(url, compiled, count) do
    Enum.reduce_while(1..count, :ok, fn index, :ok ->
      case one(url, compiled, index) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp one(url, compiled, index) do
    {relationships, assertion} = case_for(index)

    with {:ok, tuples} <- tuples(relationships),
         :ok <- spice_write(url, relationships),
         {:ok, spice} <- spice_check(url, assertion),
         {:ok, licet} <- licet_check(compiled, tuples, assertion) do
      if spice == licet do
        :ok
      else
        {:error, {assertion, spice, licet}}
      end
    end
  end

  defp schema do
    """
    definition user {}
    definition document {
      relation owner: user
      relation viewer: user
      relation parent: document
      permission view = owner + viewer + parent->view
    }
    """
  end

  defp case_for(index) do
    anne = rem(index, 3) == 0
    bob = rem(index, 5) == 0
    parent = rem(index, 7) == 0

    relationships =
      ["document:doc#{index}#owner@user:ada"] ++
        if(bob, do: ["document:doc#{index}#viewer@user:bob"], else: []) ++
        if(parent,
          do: ["document:doc#{index}#parent@document:root", "document:root#viewer@user:cara"],
          else: []
        )

    subject = if anne, do: "user:ada", else: "user:bob"
    {relationships, "document:doc#{index}#view@#{subject}"}
  end

  defp tuples(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case Licet.Relationship.parse(line) do
        {:ok, rel} -> {:cont, {:ok, [rel | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp licet_check(schema, tuples, assertion) do
    {:ok, rel} = Licet.Relationship.parse(assertion)
    reader = %Licet.Reader.Memory{tuples: tuples}
    revision = %{snapshot: "0:0:", own_xid: "", at: ~U[2099-01-01 00:00:00Z]}
    resource = %{type: rel.resource_type, id: rel.resource_id, relation: ""}
    subject = %{type: rel.subject_type, id: rel.subject_id, relation: rel.subject_relation}

    case Licet.Engine.check(schema, reader, revision, resource, rel.relation, subject,
           parallel: nil
         ) do
      {:ok, answer} -> {:ok, answer == :allowed}
      {:error, error} -> {:error, error}
    end
  end

  defp spice_schema(url, schema) do
    post(url, "/v1/schema/write", %{"schema" => schema})
  end

  defp spice_write(url, relationships) do
    updates =
      Enum.map(relationships, fn line ->
        {:ok, rel} = Licet.Relationship.parse(line)

        %{
          "operation" => "OPERATION_TOUCH",
          "relationship" => %{
            "resource" => %{"objectType" => rel.resource_type, "objectId" => rel.resource_id},
            "relation" => rel.relation,
            "subject" => %{
              "object" => %{"objectType" => rel.subject_type, "objectId" => rel.subject_id}
            }
          }
        }
      end)

    post(url, "/v1/relationships/write", %{"updates" => updates})
  end

  defp spice_check(url, assertion) do
    {:ok, rel} = Licet.Relationship.parse(assertion)

    body = %{
      "consistency" => %{"fullyConsistent" => true},
      "resource" => %{"objectType" => rel.resource_type, "objectId" => rel.resource_id},
      "permission" => rel.relation,
      "subject" => %{
        "object" => %{"objectType" => rel.subject_type, "objectId" => rel.subject_id}
      }
    }

    case Req.post(url <> "/v1/permissions/check", json: body, headers: headers()) do
      {:ok, %{status: 200, body: %{"permissionship" => "PERMISSIONSHIP_HAS_PERMISSION"}}} ->
        {:ok, true}

      {:ok, %{status: 200, body: %{"permissionship" => "PERMISSIONSHIP_NO_PERMISSION"}}} ->
        {:ok, false}

      other ->
        {:error, other}
    end
  end

  defp post(url, path, body) do
    case Req.post(url <> path, json: body, headers: headers()) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> {:error, other}
    end
  end

  defp headers do
    [{"authorization", "Bearer test"}]
  end
end
