defmodule Licet.ExplainTest do
  use ExUnit.Case, async: true

  alias Licet.Engine
  alias Licet.Reader.Memory
  alias Licet.Relationship
  alias Licet.Schema

  @revision %{snapshot: "0:0:", own_xid: "", at: ~U[2026-01-01 00:00:00Z]}

  test "an arrow grant appears in the explain trace" do
    schema = """
    definition user {}

    definition group {
      relation member: user | group#member
    }

    definition folder {
      relation viewer: user | group#member
    }

    definition document {
      relation parent: folder
      relation editor: user
      relation viewer: user | user:* | group#member
      relation banned: user

      permission edit = editor
      permission view = (viewer + edit + parent->viewer) - banned
    }
    """

    relationships = """
    document:readme#editor@user:anne
    document:readme#parent@folder:handbook
    folder:handbook#viewer@group:engineering#member
    group:engineering#member@user:beth
    group:engineering#member@group:platform#member
    group:platform#member@user:carl
    """

    assert {:ok, :allowed, trace} =
             explain(schema, relationships, "document:readme", "view", "user:carl")

    assert trace.resource == "document:readme"
    assert trace.permission == "view"
    assert trace.result == :allowed
    assert trace_text(trace) =~ "folder:handbook#viewer"
    assert trace_text(trace) =~ "group:"
  end

  test "a direct relation allow has a shallow trace" do
    schema = """
    definition user {}
    definition document {
      relation viewer: user
      permission view = viewer
    }
    """

    assert {:ok, :allowed, trace} =
             explain(schema, "document:1#viewer@user:ada", "document:1", "view", "user:ada")

    assert trace == %{
             resource: "document:1",
             permission: "view",
             result: :allowed,
             children: [
               %{
                 resource: "document:1",
                 permission: "viewer",
                 result: :allowed,
                 children: []
               }
             ]
           }
  end

  defp explain(schema, relationships, resource, permission, subject) do
    {:ok, compiled} = Schema.parse(schema)

    tuples =
      relationships
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "//")))
      |> Enum.map(fn line ->
        {:ok, rel} = Relationship.parse(line)
        rel
      end)

    {:ok, resource_type, resource_id, _} = Relationship.parse_object(resource)
    {:ok, subject_type, subject_id, subject_relation} = Relationship.parse_object(subject)

    Engine.explain(
      compiled,
      %Memory{tuples: tuples},
      @revision,
      %{type: resource_type, id: resource_id, relation: ""},
      permission,
      %{type: subject_type, id: subject_id, relation: subject_relation},
      timeout: 5_000
    )
  end

  defp trace_text(trace), do: format(trace, 0)

  defp format(%{resource: resource, permission: permission, result: result} = trace, depth) do
    indent = String.duplicate("  ", depth)
    line = "#{indent}#{resource}##{permission}: #{result}"

    case Map.get(trace, :children, []) do
      [] -> line
      children -> line <> "\n" <> Enum.map_join(children, "\n", &format(&1, depth + 1))
    end
  end
end
