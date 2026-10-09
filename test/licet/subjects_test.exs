defmodule Licet.SubjectsTest do
  use ExUnit.Case, async: true

  alias Licet.Engine.Subjects
  alias Licet.Reader.Memory
  alias Licet.Reader.Postgres
  alias Licet.Relationship
  alias Licet.Validate

  test "default struct builders run" do
    assert %Subjects{} = Subjects.__struct__(sets: %{})
    assert %Memory{tuples: []} = Memory.__struct__(tuples: [])
    assert %Postgres{} = Postgres.__struct__([])
    assert %Relationship{} = Relationship.__struct__([])
    assert %Validate{relationships: []} = Validate.__struct__([])
  end

  defp set(ids), do: Enum.reduce(ids, Subjects.empty(), &Subjects.add(&2, "user", &1))

  defp listed(set) do
    Enum.map(Subjects.to_list(set), fn
      %{subject: {_type, "*", _relation}, excluded: excluded} -> {"*", excluded}
      %{subject: {_type, id, _relation}} -> id
    end)
  end

  test "a wildcard keeps the concrete subjects next to it" do
    assert listed(Subjects.union(set(["ada"]), set(["*"]))) == [{"*", []}, "ada"]
    assert listed(set(["*", "ada"])) == [{"*", []}, "ada"]
    assert Subjects.count(set(["*", "ada"])) == 2
  end

  test "removing a subject from a wildcard records it as excluded" do
    assert listed(Subjects.difference(set(["*"]), set(["dan"]))) == [{"*", ["dan"]}]

    assert listed(Subjects.difference(set(["*", "dan", "tom"]), set(["dan"]))) == [
             {"*", ["dan"]},
             "tom"
           ]
  end

  test "adding an excluded subject back lifts the exclusion" do
    banned = Subjects.difference(set(["*"]), set(["dan"]))
    assert listed(Subjects.union(banned, set(["dan"]))) == [{"*", []}, "dan"]
    assert listed(Subjects.union(set(["dan"]), banned)) == [{"*", []}, "dan"]

    other = Subjects.difference(set(["*"]), set(["eve"]))
    assert listed(Subjects.union(banned, other)) == [{"*", []}]
    assert listed(Subjects.union(banned, banned)) == [{"*", ["dan"]}]
  end

  test "intersections keep the concrete subjects a wildcard allows" do
    banned = Subjects.difference(set(["*"]), set(["dan"]))

    assert listed(Subjects.intersection(set(["ada", "dan"]), banned)) == ["ada"]
    assert listed(Subjects.intersection(banned, set(["ada", "dan"]))) == ["ada"]
    assert listed(Subjects.intersection(set(["ada", "bob"]), set(["ada"]))) == ["ada"]
    assert listed(Subjects.intersection(set(["*"]), set(["*"]))) == [{"*", []}]

    other = Subjects.difference(set(["*"]), set(["eve"]))
    assert listed(Subjects.intersection(banned, other)) == [{"*", ["dan", "eve"]}]
    assert listed(Subjects.intersection(set(["ada"]), Subjects.empty())) == []
  end

  test "subtracting a wildcard keeps only what it excluded" do
    banned = Subjects.difference(set(["*"]), set(["dan"]))

    assert listed(Subjects.difference(set(["ada"]), set(["*"]))) == []
    assert listed(Subjects.difference(set(["*"]), set(["*"]))) == []
    assert listed(Subjects.difference(set(["ada", "dan"]), banned)) == ["dan"]
    assert listed(Subjects.difference(set(["*"]), banned)) == ["dan"]

    eve = Subjects.difference(set(["*"]), set(["eve"]))
    assert listed(Subjects.difference(eve, banned)) == ["dan"]
    assert listed(Subjects.difference(banned, banned)) == []
  end

  test "groups subjects by type and relation" do
    mixed =
      Subjects.empty()
      |> Subjects.add("user", "ada")
      |> Subjects.add("team", "eng", "member")
      |> Subjects.add("team", "ops")

    assert Subjects.to_list(Subjects.only(mixed, "team", "member")) == [
             %{subject: {"team", "eng", "member"}, excluded: []}
           ]

    assert Subjects.to_list(
             Subjects.difference(mixed, Subjects.add(Subjects.empty(), "user", "ada"))
           ) == [
             %{subject: {"team", "eng", "member"}, excluded: []},
             %{subject: {"team", "ops", ""}, excluded: []}
           ]
  end
end
