defmodule Licet.OperatorsTest do
  use ExUnit.Case, async: true

  alias Licet.Engine
  alias Licet.Engine.Subjects
  alias Licet.Reader.Memory
  alias Licet.Relationship
  alias Licet.Schema

  @schema """
  definition user {}

  definition team {
    relation direct_member: user
    permission member = direct_member
  }

  definition resource {
    relation team: team
    relation viewer: user
    permission view_by_all = team.all(member)
    permission view_by_any = team.any(member)
    permission empty = nil
    permission viewer_or_nil = viewer + nil
    permission viewer_minus_nil = viewer - nil
    permission nil_minus_viewer = nil - viewer
    permission viewer_and_nil = viewer & nil
  }
  """

  @tuples """
  team:first#direct_member@user:tom
  team:first#direct_member@user:fred
  team:first#direct_member@user:sarah
  team:second#direct_member@user:fred
  team:second#direct_member@user:sarah
  team:third#direct_member@user:sarah
  resource:oneteam#team@team:first
  resource:twoteams#team@team:first
  resource:twoteams#team@team:second
  resource:threeteams#team@team:first
  resource:threeteams#team@team:second
  resource:threeteams#team@team:third
  resource:first#viewer@user:tom
  """

  describe ".all() and .any()" do
    test "all requires every related object, any requires one" do
      assert check("resource:oneteam", "view_by_all", "user:tom") == {:ok, :allowed}
      assert check("resource:twoteams", "view_by_all", "user:fred") == {:ok, :allowed}
      assert check("resource:threeteams", "view_by_all", "user:sarah") == {:ok, :allowed}
      assert check("resource:twoteams", "view_by_all", "user:tom") == {:ok, :denied}
      assert check("resource:threeteams", "view_by_all", "user:fred") == {:ok, :denied}
      assert check("resource:threeteams", "view_by_any", "user:tom") == {:ok, :allowed}
    end

    test "all with no related object denies" do
      assert check("resource:first", "view_by_all", "user:tom") == {:ok, :denied}
    end

    test "lookup_subjects intersects the related objects for all" do
      assert {:ok, set} = subjects("resource:threeteams", "view_by_all")
      assert found(set) == [{"user", "sarah", ""}]

      assert {:ok, set} = subjects("resource:twoteams", "view_by_all")
      assert found(set) == [{"user", "fred", ""}, {"user", "sarah", ""}]

      assert {:ok, set} = subjects("resource:first", "view_by_all")
      assert found(set) == []
    end

    test "lookup_resources keeps only resources where every related object grants" do
      assert {:ok, ids} = resources("view_by_all", "user:fred")
      assert ids == MapSet.new(["oneteam", "twoteams"])

      assert {:ok, ids} = resources("view_by_any", "user:tom")
      assert ids == MapSet.new(["oneteam", "twoteams", "threeteams"])
    end

    test "propagates errors from every related object" do
      depth = [max_depth: 0]

      assert {:error, %{reason: :depth_exceeded}} =
               check("resource:threeteams", "view_by_all", "user:sarah", depth)

      assert {:error, %{reason: :depth_exceeded}} =
               subjects("resource:threeteams", "view_by_all", depth)

      assert {:error, %{reason: :depth_exceeded}} = resources("view_by_all", "user:sarah", depth)
    end

    test "round-trips through to_zed" do
      {:ok, schema} = Schema.parse(@schema)
      zed = Schema.to_zed(schema)
      assert zed =~ "team.all(member)"
      assert {:ok, again} = Schema.parse(zed)
      assert again.definitions == schema.definitions
    end

    test "rejects an unknown arrow function" do
      assert {:error, %{message: message}} =
               Schema.parse("""
               definition user {}
               definition team {
                 relation member: user
               }
               definition resource {
                 relation team: team
                 permission view = team.some(member)
               }
               """)

      assert message =~ ".all"
    end
  end

  describe "nil" do
    test "is the empty set in every operator" do
      assert check("resource:first", "empty", "user:tom") == {:ok, :denied}
      assert check("resource:first", "viewer_or_nil", "user:tom") == {:ok, :allowed}
      assert check("resource:first", "viewer_minus_nil", "user:tom") == {:ok, :allowed}
      assert check("resource:first", "nil_minus_viewer", "user:tom") == {:ok, :denied}
      assert check("resource:first", "viewer_and_nil", "user:tom") == {:ok, :denied}
    end

    test "has no subjects and no resources" do
      assert {:ok, set} = subjects("resource:first", "empty")
      assert found(set) == []
      assert resources("empty", "user:tom") == {:ok, MapSet.new()}
    end
  end

  test "a userset subject is a member of itself" do
    assert check("resource:first", "viewer", "resource:first#viewer") == {:ok, :allowed}

    assert check("resource:first", "viewer_or_nil", "resource:first#viewer_or_nil") ==
             {:ok, :allowed}

    assert check("resource:first", "viewer", "resource:first#empty") == {:ok, :denied}
  end

  test "precedence matches SpiceDB: + binds tighter than &, & tighter than -" do
    {:ok, schema} =
      Schema.parse("""
      definition user {}
      definition document {
        relation one: user
        relation two: user
        relation three: user
        permission minus_and = one - two & three
        permission and_plus = one & two + three
        permission grouped = (one - two) & (three - one)
        permission nested = one - (two - three)
      }
      """)

    permissions = schema.definitions["document"].permissions

    assert permissions["minus_and"] ==
             {:exclusion, {:ref, "one"}, {:intersection, {:ref, "two"}, {:ref, "three"}}}

    assert permissions["and_plus"] ==
             {:intersection, {:ref, "one"}, {:union, {:ref, "two"}, {:ref, "three"}}}

    zed = Schema.to_zed(schema)
    assert zed =~ "(one - two) & (three - one)"
    assert zed =~ "one - (two - three)"
    assert {:ok, again} = Schema.parse(zed)
    assert again.definitions == schema.definitions
  end

  test "rejects self" do
    assert {:error, %{message: "self is not supported"}} =
             Schema.parse("definition user {\n  permission myself = self\n}")
  end

  test "reads #... as a subject with no relation" do
    assert {:ok, %{subject_relation: ""}} =
             Relationship.parse("document:1#viewer@user:ada#...")

    assert {:ok, "user", "ada", ""} = Relationship.parse_object("user:ada#...")
  end

  defp check(resource, permission, subject, opts \\ []) do
    Engine.check(
      schema(),
      reader(),
      revision(),
      object(resource),
      permission,
      object(subject),
      opts
    )
  end

  defp subjects(resource, permission, opts \\ []) do
    %{type: type, id: id} = object(resource)
    Engine.subject_set(schema(), reader(), revision(), type, id, permission, {"user", ""}, opts)
  end

  defp found(set), do: Enum.map(Subjects.to_list(set), & &1.subject)

  defp resources(permission, subject, opts \\ []) do
    Engine.resource_ids(
      schema(),
      reader(),
      revision(),
      "resource",
      permission,
      object(subject),
      opts
    )
  end

  defp schema do
    {:ok, schema} = Schema.parse(@schema)
    schema
  end

  defp reader do
    tuples =
      @tuples
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        {:ok, rel} = Relationship.parse(line)
        rel
      end)

    %Memory{tuples: tuples}
  end

  defp revision, do: %{snapshot: "1:1:", own_xid: "", at: ~U[2099-01-01 00:00:00Z]}

  defp object(value) do
    {:ok, type, id, relation} = Relationship.parse_object(value)
    %{type: type, id: id, relation: relation}
  end
end
