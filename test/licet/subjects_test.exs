defmodule Licet.SubjectsTest do
  use ExUnit.Case, async: true

  alias Licet.Engine.Subjects
  alias Licet.Reader.Memory
  alias Licet.Reader.Postgres
  alias Licet.Relationship

  test "default struct builders run" do
    assert %Subjects{} = Subjects.__struct__(concrete: %{})
    assert %Memory{tuples: []} = Memory.__struct__(tuples: [])
    assert %Postgres{} = Postgres.__struct__([])
    assert %Relationship{} = Relationship.__struct__([])
  end

  test "unions, intersects, and subtracts wildcards" do
    all = Subjects.allow_all(Subjects.empty(), "user")
    ada = Subjects.add(Subjects.empty(), "user", "ada")
    bob = Subjects.add(Subjects.empty(), "user", "bob")

    union = Subjects.union(ada, all)
    assert Subjects.to_list(union) == [{"user", "*", ""}]

    both = Subjects.intersection(Subjects.union(ada, bob), ada)
    assert Subjects.to_list(both) == [{"user", "ada", ""}]

    assert Subjects.to_list(Subjects.difference(all, ada)) == [{"user", "*", ""}]
    assert Subjects.count(Subjects.difference(ada, bob)) == 1
    assert Subjects.to_list(Subjects.difference(all, all)) == []
    assert Subjects.to_list(Subjects.intersection(all, all)) == [{"user", "*", ""}]
    assert Subjects.to_list(Subjects.intersection(all, ada)) == [{"user", "ada", ""}]
    assert Subjects.to_list(Subjects.intersection(ada, all)) == [{"user", "ada", ""}]
    assert Subjects.to_list(Subjects.difference(ada, all)) == []

    excluded = Subjects.difference(all, ada)
    other = Subjects.difference(all, bob)
    assert Subjects.to_list(Subjects.union(excluded, other)) == [{"user", "*", ""}]
    assert Subjects.to_list(Subjects.union(excluded, ada)) == [{"user", "*", ""}]
  end
end
