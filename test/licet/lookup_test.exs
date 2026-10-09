defmodule Licet.LookupTest do
  use ExUnit.Case, async: true

  alias Licet.Engine
  alias Licet.Reader.Memory
  alias Licet.Relationship
  alias Licet.Schema

  @schema """
  definition user {}

  definition group {
    relation member: user | group#member
  }

  definition folder {
    relation parent: folder
    relation viewer: user | user:* | group#member
    relation banned: user
    permission view = viewer + parent->view
    permission blocked = banned + parent->blocked
  }

  definition document {
    relation parent: folder | folder:*
    relation owner: user
    permission view = owner + parent->view
    permission visible = view - parent->blocked
    permission grandparent_view = parent->parent->view
  }
  """

  @tuples """
  group:eng#member@user:ada
  group:all#member@group:eng#member
  folder:root#viewer@group:all#member
  folder:mid#parent@folder:root
  folder:leaf#parent@folder:mid
  folder:mid#banned@user:ada
  folder:public#viewer@user:*
  folder:loop1#parent@folder:loop2
  folder:loop2#parent@folder:loop1
  folder:loop1#viewer@user:bob
  document:a#parent@folder:leaf
  document:b#parent@folder:root
  document:c#owner@user:ada
  document:d#parent@folder:public
  document:e#parent@folder:*
  """

  @documents ~w(a b c d e)

  test "walks recursive folders, nested groups, and wildcards back from the subject" do
    assert resources("document", "view", "user:ada") == {:ok, MapSet.new(~w(a b c d))}
    assert resources("document", "view", "user:carol") == {:ok, MapSet.new(~w(d))}
  end

  test "subtracts a recursive permission by checking each candidate" do
    assert resources("document", "visible", "user:ada") == {:ok, MapSet.new(~w(b c d))}
  end

  test "follows chained arrows" do
    assert resources("document", "grandparent_view", "user:ada") == {:ok, MapSet.new(~w(a))}
  end

  test "a userset subject finds what its members can reach" do
    assert resources("document", "view", "group:eng#member") == {:ok, MapSet.new(~w(a b))}
  end

  test "agrees with a check of every document" do
    for permission <- ~w(view visible grandparent_view),
        subject <- ~w(user:ada user:carol group:eng#member group:all#member) do
      expected =
        MapSet.new(for id <- @documents, check("document:" <> id, permission, subject), do: id)

      assert resources("document", permission, subject) == {:ok, expected},
             "#{permission} for #{subject}"
    end
  end

  test "terminates on cyclic data" do
    assert resources("folder", "view", "user:bob") == {:ok, MapSet.new(~w(loop1 loop2 public))}
  end

  test "an arrow does not follow a wildcard target" do
    refute check("document:e", "view", "user:ada")
  end

  test "propagates a limit reached inside a userset or an arrow" do
    assert {:error, %{reason: :lookup_too_large}} =
             resources("document", "grandparent_view", "user:ada", max_lookup: 1)
  end

  defp resources(type, permission, subject, opts \\ []) do
    Engine.resource_ids(schema(), reader(), revision(), type, permission, object(subject), opts)
  end

  defp check(resource, permission, subject) do
    {:ok, answer} =
      Engine.check(schema(), reader(), revision(), object(resource), permission, object(subject))

    answer == :allowed
  end

  defp schema do
    {:ok, schema} = Schema.parse(@schema)
    schema
  end

  defp reader do
    tuples =
      for line <- String.split(@tuples, "\n", trim: true) do
        {:ok, rel} = Relationship.parse(line)
        rel
      end

    %Memory{tuples: tuples}
  end

  defp revision, do: %{snapshot: "1:1:", own_xid: "", at: ~U[2099-01-01 00:00:00Z]}

  defp object(value) do
    {:ok, type, id, relation} = Relationship.parse_object(value)
    %{type: type, id: id, relation: relation}
  end
end
