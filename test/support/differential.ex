defmodule Licet.Differential do
  @moduledoc false

  alias Licet.SpiceDB

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
    url = SpiceDB.url()
    schema = schema()

    with {:ok, compiled} <- Licet.Schema.parse(schema),
         :ok <- SpiceDB.load(url, schema, []) do
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
         :ok <- SpiceDB.write(url, tuples),
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

  defp spice_check(url, assertion) do
    {:ok, rel} = Licet.Relationship.parse(assertion)

    request =
      {{rel.resource_type, rel.resource_id}, rel.relation,
       {rel.subject_type, rel.subject_id, rel.subject_relation}}

    case SpiceDB.check_bulk(url, [request]) do
      {:ok, [answer]} -> answer
      error -> error
    end
  end
end
