defmodule Licet.CheckSetTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Licet.Engine

  @schema """
  definition user {}

  definition group {
    relation member: user | user:* | group#member
  }

  definition folder {
    relation parent: folder
    relation viewer: user | group#member
    relation banned: user
    permission view = viewer + parent->view
    permission browse = view - banned
  }

  definition document {
    relation parent: folder
    relation owner: user
    relation viewer: user | user:* | group#member
    relation banned: user | group#member
    permission edit = owner
    permission view = edit + viewer + parent->view
    permission read = view - banned
    permission strict = view & parent->browse
    permission every = parent.all(browse)
    permission grand = parent->parent->view
  }
  """

  @users ["a", "b", "c"]
  @groups ["g1", "g2", "g3"]
  @folders ["f1", "f2", "f3"]
  @documents ["d1", "d2", "d3", "d4"]

  property "answers like the tree evaluator" do
    {:ok, schema} = Licet.Schema.parse(@schema)

    check all(
            lines <- list_of(relationship(), max_length: 25),
            {type, permission} <- permission(),
            subject <- subject(),
            max_depth <- member_of([1, 3, 50])
          ) do
      reader = reader(Enum.uniq(lines))
      ids = if type == "document", do: @documents, else: @folders
      opts = [max_depth: max_depth]
      results = Engine.check_set(schema, reader, revision(), type, ids, permission, subject, opts)

      for id <- ids do
        resource = %{type: type, id: id, relation: ""}
        tree = Engine.explain(schema, reader, revision(), resource, permission, subject, opts)
        agree!(tree, Map.fetch!(results, id), {type, id, permission, subject, lines})
      end
    end
  end

  # The tree stops at the first error it meets, so it can fail where another
  # branch allows. Whenever it answers, the set evaluator gives the same answer.
  defp agree!({:ok, answer, _trace}, result, context),
    do: assert(result == answer, inspect(context))

  defp agree!({:error, _}, {:error, _}, _context), do: :ok
  defp agree!({:error, _}, :allowed, _context), do: :ok
  defp agree!({:error, _}, :denied, _context), do: :ok

  test "an allowed branch wins over a failing one" do
    schema = """
    definition user {}
    definition document {
      relation parent: document
      relation owner: user
      permission view = parent->view + owner
    }
    """

    cycle = ["document:1#parent@document:2", "document:2#parent@document:1"]

    owned =
      check_set(schema, ["document:1#owner@user:ada" | cycle], "document", ["1", "2"], "view")

    assert owned == %{"1" => :allowed, "2" => :allowed}

    targets = [
      "document:1#parent@document:2",
      "document:1#parent@document:3",
      "document:2#parent@document:1",
      "document:3#owner@user:ada"
    ]

    assert %{"1" => :allowed} = check_set(schema, targets, "document", ["1"], "view")
  end

  test "a cycle with no allowed branch fails with :cycle" do
    schema = """
    definition user {}
    definition group {
      relation member: user | group#member
    }
    """

    tuples = ["group:a#member@group:b#member", "group:b#member@group:a#member"]

    assert %{"a" => {:error, %{reason: :cycle}}, "b" => {:error, %{reason: :cycle}}} =
             check_set(schema, tuples, "group", ["a", "b"], "member")

    banned = [
      "document:1#owner@user:ada",
      "document:1#banned@group:g1#member",
      "group:g1#member@group:g2#member",
      "group:g2#member@group:g1#member"
    ]

    assert %{"1" => {:error, %{reason: :cycle}}} =
             check_set(@schema, banned, "document", ["1"], "read")
  end

  test ".all() needs a target and every target, per resource" do
    tuples = [
      "document:1#parent@folder:f1",
      "document:1#parent@folder:f2",
      "document:2#parent@folder:f1",
      "document:2#parent@folder:f3",
      "folder:f1#viewer@user:ada",
      "folder:f2#viewer@user:ada",
      "folder:f3#viewer@user:ada",
      "folder:f3#banned@user:ada"
    ]

    assert check_set(@schema, tuples, "document", ["1", "2", "3"], "every") ==
             %{"1" => :allowed, "2" => :denied, "3" => :denied}
  end

  test "reads every relation of one level in one query" do
    tuples =
      for d <- 1..20 do
        ["document:d#{d}#parent@folder:f1", "document:d#{d}#viewer@user:u#{d}"]
      end

    reader = counting_reader(List.flatten(["folder:f1#viewer@user:ada" | tuples]))
    {:ok, schema} = Licet.Schema.parse(@schema)
    ids = for d <- 1..20, do: "d#{d}"

    results = Engine.check_set(schema, reader, revision(), "document", ids, "view", user("ada"))
    assert Enum.all?(results, fn {_id, answer} -> answer == :allowed end)
    assert queries() == 2
  end

  test "reads a relation again for objects the level did not cover" do
    schema = """
    definition user {}
    definition document {
      relation parent: document
      relation viewer: user
      permission view = viewer + parent->viewer
    }
    """

    tuples = ["document:1#parent@document:2", "document:2#viewer@user:ada"]

    assert check_set(schema, tuples, "document", ["1", "3"], "view") == %{
             "1" => :allowed,
             "3" => :denied
           }

    assert check_set(schema, tuples, "document", [], "view") == %{}
  end

  test "reports schema errors and limits for every id" do
    assert %{"1" => {:error, %{reason: :unknown_type}}} =
             check_set(@schema, [], "missing", ["1"], "view")

    assert %{"1" => {:error, %{reason: :unknown_relation}}} =
             check_set(@schema, [], "document", ["1"], "missing")

    assert %{"1" => {:error, %{reason: :timeout}}, "2" => {:error, %{reason: :timeout}}} =
             check_set(@schema, [], "document", ["1", "2", "1"], "view", timeout: 0)

    deep = ["document:1#parent@folder:f1", "folder:f1#parent@folder:f2"]

    assert %{"1" => {:error, %{reason: :depth_exceeded}}} =
             check_set(@schema, deep, "document", ["1"], "view", max_depth: 1)
  end

  test "a userset subject is allowed on itself and through nesting" do
    tuples = ["group:g1#member@group:g2#member", "group:g2#member@user:ada"]
    {:ok, schema} = Licet.Schema.parse(@schema)
    subject = %{type: "group", id: "g2", relation: "member"}

    assert Engine.check_set(
             schema,
             reader(tuples),
             revision(),
             "group",
             ["g1", "g2", "g3"],
             "member",
             subject
           ) ==
             %{"g1" => :allowed, "g2" => :allowed, "g3" => :denied}
  end

  defp relationship do
    one_of([
      bind(tuple({member_of(@groups), group_subject()}), fn {g, s} ->
        constant("group:#{g}#member@#{s}")
      end),
      bind(tuple({member_of(@folders), member_of(@folders)}), fn {f, p} ->
        constant("folder:#{f}#parent@folder:#{p}")
      end),
      bind(
        tuple({member_of(@folders), member_of(Enum.map(@users, &"user:#{&1}") ++ usersets())}),
        fn {f, s} ->
          constant("folder:#{f}#viewer@#{s}")
        end
      ),
      bind(tuple({member_of(@folders), member_of(@users)}), fn {f, u} ->
        constant("folder:#{f}#banned@user:#{u}")
      end),
      bind(tuple({member_of(@documents), member_of(@folders)}), fn {d, f} ->
        constant("document:#{d}#parent@folder:#{f}")
      end),
      bind(tuple({member_of(@documents), member_of(@users)}), fn {d, u} ->
        constant("document:#{d}#owner@user:#{u}")
      end),
      bind(tuple({member_of(@documents), group_subject()}), fn {d, s} ->
        constant("document:#{d}#viewer@#{s}")
      end),
      bind(
        tuple({member_of(@documents), member_of(Enum.map(@users, &"user:#{&1}") ++ usersets())}),
        fn {d, s} ->
          constant("document:#{d}#banned@#{s}")
        end
      )
    ])
  end

  defp group_subject do
    member_of(Enum.map(@users, &"user:#{&1}") ++ ["user:*" | usersets()])
  end

  defp usersets, do: Enum.map(@groups, &"group:#{&1}#member")

  defp permission do
    member_of([
      {"document", "view"},
      {"document", "read"},
      {"document", "strict"},
      {"document", "every"},
      {"document", "grand"},
      {"document", "viewer"},
      {"folder", "view"},
      {"folder", "browse"}
    ])
  end

  defp subject do
    member_of(Enum.map(@users, &user/1) ++ [%{type: "group", id: "g1", relation: "member"}])
  end

  defp check_set(schema, tuples, type, ids, permission, opts \\ []) do
    {:ok, schema} = Licet.Schema.parse(schema)
    Engine.check_set(schema, reader(tuples), revision(), type, ids, permission, user("ada"), opts)
  end

  defp user(id), do: %{type: "user", id: id, relation: ""}

  defp reader(lines) do
    %Licet.Reader.Memory{tuples: Enum.map(lines, &elem(Licet.Relationship.parse(&1), 1))}
  end

  defp counting_reader(lines), do: %Licet.CountingReader{memory: reader(lines), test: self()}

  defp queries(count \\ 0) do
    receive do
      :listed -> queries(count + 1)
    after
      0 -> count
    end
  end

  defp revision, do: %{snapshot: "1:1:", own_xid: "", at: ~U[2099-01-01 00:00:00Z]}
end
