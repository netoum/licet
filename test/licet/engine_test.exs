defmodule Licet.EngineTest do
  use ExUnit.Case, async: true

  alias Licet.Engine.Subjects

  @schema """
  definition user {}
  definition team {
    relation member: user
  }
  definition document {
    relation owner: user
    relation viewer: user | user:* | team#member
    relation parent: document
    permission view = owner + viewer + parent->view
    permission deep = parent->parent->view
    permission edit = owner
    permission share = edit & viewer
    permission secret = view - viewer
  }
  """

  test "allows direct, union, wildcard, userset, and arrow relationships" do
    assert {:ok, :allowed} = check("document:1#owner@user:ada", "document:1", "view", "user:ada")
    assert {:ok, :denied} = check("document:1#owner@user:ada", "document:1", "view", "user:bob")
    assert {:ok, :allowed} = check("document:1#viewer@user:*", "document:1", "view", "user:bob")

    assert {:ok, :allowed} =
             check(
               "document:1#viewer@team:eng#member\nteam:eng#member@user:cara",
               "document:1",
               "view",
               "user:cara"
             )

    assert {:ok, :allowed} =
             check(
               "document:1#parent@document:2\ndocument:2#owner@user:ada",
               "document:1",
               "view",
               "user:ada"
             )
  end

  test "evaluates intersection and exclusion" do
    tuples = "document:1#owner@user:ada\ndocument:1#viewer@user:ada"
    assert {:ok, :allowed} = check(tuples, "document:1", "share", "user:ada")
    assert {:ok, :denied} = check("document:1#owner@user:ada", "document:1", "share", "user:ada")

    assert {:ok, :allowed} =
             check("document:1#owner@user:ada", "document:1", "secret", "user:ada")

    assert {:ok, :denied} = check(tuples, "document:1", "secret", "user:ada")

    assert {:ok, :allowed, %{result: :allowed}} =
             explain(tuples, "document:1", "share", "user:ada")
  end

  test "reports unknown types, cycles, depth, and timeout" do
    assert {:error, %{reason: :unknown_type}} = check("", "missing:1", "view", "user:ada")
    assert {:error, %{reason: :unknown_relation}} = check("", "document:1", "missing", "user:ada")

    cycle = "document:1#parent@document:2\ndocument:2#parent@document:1"
    assert {:error, %{reason: :cycle}} = check(cycle, "document:1", "view", "user:ada")

    assert {:error, %{reason: :depth_exceeded}} =
             check(cycle, "document:1", "view", "user:ada", max_depth: 1)

    assert {:error, %{reason: :timeout}} =
             check("document:1#owner@user:ada", "document:1", "view", "user:ada", timeout: 0)
  end

  test "explains an allowed check and looks up resources and subjects" do
    tuples = [
      "document:1#owner@user:ada",
      "document:2#viewer@user:ada",
      "document:2#viewer@user:*"
    ]

    assert {:ok, :allowed, %{permission: "view", result: :allowed}} =
             explain(tuples, "document:1", "view", "user:ada")

    assert {:ok, set} = subjects(tuples, "document:2", "viewer")
    assert {"user", "*", ""} in found(set)

    assert {:ok, ids} = resources(tuples, "document", "view", "user:ada")
    assert MapSet.member?(ids, "1")
    assert MapSet.member?(ids, "2")
  end

  test "explain follows the same rules as check" do
    {:ok, schema} =
      Licet.Schema.parse("""
      definition user {}
      definition team {
        relation member: user
      }
      definition folder {
        relation viewer: user
      }
      definition document {
        relation parent: folder | team
        permission none = nil
        permission every = parent.all(viewer)
        permission through = parent->viewer
      }
      """)

    tuples =
      reader([
        "document:1#parent@folder:f1",
        "document:1#parent@folder:f2",
        "document:2#parent@team:eng",
        "folder:f1#viewer@user:ada",
        "folder:f2#viewer@user:ada"
      ])

    explain = fn resource, permission, subject ->
      Licet.Engine.explain(
        schema,
        tuples,
        revision(),
        resource(resource),
        permission,
        subject(subject)
      )
    end

    assert {:ok, :allowed, _} = explain.("document:1", "every", "user:ada")
    assert {:ok, :denied, _} = explain.("document:2", "through", "user:ada")
    assert {:ok, :denied, _} = explain.("document:1", "none", "user:ada")
    assert {:ok, :allowed, _} = explain.("team:eng", "member", "team:eng#member")
    assert {:error, %{reason: :unknown_relation}} = explain.("document:1", "missing", "user:ada")

    odd = %{
      definitions: %{
        "document" => %{
          relations: %{"owner" => %{}},
          permissions: %{
            "view" => {:arrow, {:union, {:ref, "owner"}, {:ref, "owner"}}, {:ref, "owner"}}
          }
        }
      }
    }

    assert {:ok, :denied, _} =
             Licet.Engine.explain(
               odd,
               reader([]),
               revision(),
               resource("document:1"),
               "view",
               subject("user:ada")
             )
  end

  test "an arrow to a type the schema does not define reports the type" do
    {:ok, schema} = Licet.Schema.parse(@schema)

    assert {:error, %{reason: :unknown_type}} =
             Licet.Engine.check(
               schema,
               reader("document:1#parent@ghost:1"),
               revision(),
               resource("document:1"),
               "view",
               subject("user:ada")
             )
  end

  test "checks and explains without explicit options" do
    {:ok, schema} = Licet.Schema.parse(@schema)
    reader = reader("document:1#owner@user:ada")

    assert {:ok, :allowed} =
             Licet.Engine.check(
               schema,
               reader,
               revision(),
               resource("document:1"),
               "view",
               subject("user:ada")
             )

    assert {:ok, :allowed, %{result: :allowed}} =
             Licet.Engine.explain(
               schema,
               reader,
               revision(),
               resource("document:1"),
               "view",
               subject("user:ada")
             )
  end

  test "looks up intersections, exclusions, arrows, and usersets" do
    tuples = [
      "document:1#owner@user:ada",
      "document:1#viewer@user:ada",
      "document:2#owner@user:ada",
      "document:3#viewer@team:eng#member",
      "team:eng#member@user:cara",
      "document:4#parent@document:1",
      "document:5#parent@user:*",
      "document:6#viewer@user:bob"
    ]

    assert {:ok, ids} = resources(tuples, "document", "share", "user:ada")
    assert MapSet.member?(ids, "1")
    refute MapSet.member?(ids, "2")

    assert {:ok, secret} = resources(tuples, "document", "secret", "user:ada")
    assert MapSet.member?(secret, "2")
    refute MapSet.member?(secret, "1")

    assert {:ok, via_parent} = resources(tuples, "document", "view", "user:ada")
    assert MapSet.member?(via_parent, "4")

    assert {:ok, via_team} = resources(tuples, "document", "view", "user:cara")
    assert MapSet.member?(via_team, "3")

    assert {:ok, set} = subjects(tuples, "document:1", "share")
    assert {"user", "ada", ""} in found(set)
    assert {:ok, _secret_subjects} = subjects(tuples, "document:2", "secret")

    assert {:error, %{reason: :unknown_relation}} =
             resources(tuples, "document", "missing", "user:ada")

    assert {:error, %{reason: :unknown_relation}} = subjects(tuples, "document:1", "missing")
    assert {:error, %{reason: :timeout}} = subjects(tuples, "document:1", "view", timeout: 0)

    assert {:error, %{reason: :timeout}} =
             resources(tuples, "document", "view", "user:ada", timeout: 0)

    deep = [
      "document:1#parent@document:2",
      "document:2#parent@document:3",
      "document:3#owner@user:ada",
      "document:1#parent@team:eng#member"
    ]

    assert {:error, %{reason: :depth_exceeded}} =
             resources(deep, "document", "deep", "user:ada", max_depth: 0)

    assert {:ok, :allowed} = check(deep, "document:1", "deep", "user:ada")
    assert {:ok, deep_ids} = resources(deep, "document", "deep", "user:ada")
    assert MapSet.member?(deep_ids, "1")

    assert {:ok, walked} =
             subjects(
               ["document:3#viewer@team:eng#member", "team:eng#member@user:cara"],
               "document:3",
               "view"
             )

    assert {"user", "cara", ""} in found(walked)

    assert {:error, %{reason: :lookup_too_large}} =
             resources(tuples, "document", "view", "user:ada", max_lookup: 1)
  end

  test "denies userset subjects and walks failed arrows" do
    assert {:ok, :denied} =
             check("document:1#owner@user:ada", "document:1", "owner", "team:eng#member")

    assert {:error, %{reason: :depth_exceeded}} =
             check(
               "document:1#parent@document:2",
               "document:1",
               "view",
               "user:bob",
               max_depth: 0
             )

    assert {:ok, :denied} =
             check(
               "document:1#parent@document:2\ndocument:1#parent@document:3",
               "document:1",
               "view",
               "user:ada"
             )

    assert {:ok, set} =
             subjects(
               "document:4#parent@document:1\ndocument:1#owner@user:ada",
               "document:4",
               "view"
             )

    assert {"user", "ada", ""} in found(set)

    assert {:error, %{reason: :depth_exceeded}} =
             subjects("document:1#parent@document:2", "document:1", "view", max_depth: 0)

    assert {:error, %{reason: :depth_exceeded}} =
             subjects(
               "document:3#viewer@team:eng#member",
               "document:3",
               "viewer",
               max_depth: 0
             )

    assert {:error, %{reason: :depth_exceeded}} =
             resources(
               "document:3#viewer@team:eng#member",
               "document",
               "view",
               "user:cara",
               max_depth: 0
             )

    schema = %{
      definitions: %{
        "document" => %{
          relations: %{"owner" => %{}},
          permissions: %{
            "view" => {:arrow, {:union, {:ref, "owner"}, {:ref, "owner"}}, {:ref, "owner"}}
          }
        }
      }
    }

    assert {:ok, :denied} =
             Licet.Engine.check(
               schema,
               reader([]),
               revision(),
               resource("document:1"),
               "view",
               subject("user:ada")
             )

    failing_left = %{
      definitions: %{
        "document" => %{
          relations: %{"parent" => %{}, "owner" => %{}},
          permissions: %{
            "view" => {:union, {:arrow, "parent", {:ref, "view"}}, {:ref, "owner"}}
          }
        }
      }
    }

    assert {:error, %{reason: :depth_exceeded}} =
             Licet.Engine.check(
               failing_left,
               reader(["document:1#parent@document:2"]),
               revision(),
               resource("document:1"),
               "view",
               subject("user:ada"),
               max_depth: 0
             )
  end

  test "looks up subjects of one type, with usersets and wildcard exclusions" do
    tuples = [
      "document:1#viewer@user:*",
      "document:1#viewer@user:tom",
      "document:1#viewer@team:eng#member",
      "team:eng#member@user:cara"
    ]

    assert {:ok, users} = subjects(tuples, "document:1", "viewer")

    assert Subjects.to_list(users) == [
             %{subject: {"user", "*", ""}, excluded: []},
             %{subject: {"user", "cara", ""}, excluded: []},
             %{subject: {"user", "tom", ""}, excluded: []}
           ]

    assert {:ok, teams} = subjects(tuples, "document:1", "viewer", of: {"team", "member"})
    assert found(teams) == [{"team", "eng", "member"}]

    assert {:ok, itself} = subjects(tuples, "team:eng", "member", of: {"team", "member"})
    assert found(itself) == [{"team", "eng", "member"}]

    assert {:ok, none} = subjects(tuples, "document:1", "viewer", of: {"team", ""})
    assert found(none) == []
  end

  test "rejects lookups that exceed the cap" do
    tuples = for n <- 1..3, do: "document:1#viewer@user:u#{n}"

    assert {:error, %{reason: :lookup_too_large}} =
             subjects(tuples, "document:1", "viewer", max_lookup: 2)
  end

  defp check(tuples, resource, permission, subject, opts \\ []) do
    run(tuples, resource, permission, subject, opts, :check)
  end

  defp explain(tuples, resource, permission, subject) do
    run(tuples, resource, permission, subject, [], :explain)
  end

  defp run(tuples, resource, permission, subject, opts, fun) do
    {:ok, schema} = Licet.Schema.parse(@schema)

    apply(Licet.Engine, fun, [
      schema,
      reader(tuples),
      revision(),
      resource(resource),
      permission,
      subject(subject),
      opts
    ])
  end

  defp subjects(tuples, resource, permission, opts \\ []) do
    {:ok, schema} = Licet.Schema.parse(@schema)
    %{type: type, id: id} = resource(resource)
    {subject_type, opts} = Keyword.pop(opts, :of, {"user", ""})

    Licet.Engine.subject_set(
      schema,
      reader(tuples),
      revision(),
      type,
      id,
      permission,
      subject_type,
      opts
    )
  end

  defp found(set), do: Enum.map(Subjects.to_list(set), & &1.subject)

  defp resources(tuples, type, permission, subject, opts \\ []) do
    {:ok, schema} = Licet.Schema.parse(@schema)

    Licet.Engine.resource_ids(
      schema,
      reader(tuples),
      revision(),
      type,
      permission,
      subject(subject),
      opts
    )
  end

  defp reader(tuples) when is_binary(tuples), do: reader(String.split(tuples, "\n", trim: true))

  defp reader(lines) do
    tuples =
      Enum.map(lines, fn line ->
        {:ok, rel} = Licet.Relationship.parse(line)
        rel
      end)

    %Licet.Reader.Memory{tuples: tuples}
  end

  defp revision, do: %{snapshot: "1:1:", own_xid: "", at: ~U[2099-01-01 00:00:00Z]}

  defp resource(value) do
    {:ok, type, id, relation} = Licet.Relationship.parse_object(value)
    %{type: type, id: id, relation: relation}
  end

  defp subject(value), do: resource(value)
end
