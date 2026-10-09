defmodule Licet.SchemaTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import StreamData

  alias Licet.Schema.Diff

  @sample """
  use expiration
  // comment
  definition user {}
  definition team {
    relation member: user
  }
  definition document {
    relation owner: user
    relation viewer: user:* | team#member with expiration
    relation parent: document
    permission edit = owner
    permission view = owner + viewer + parent->view
    permission share = edit & viewer
    permission secret = view - viewer
  }
  definition docs/folder {
    relation owner: user
  }
  """

  test "parses the supported schema and round-trips it" do
    assert {:ok, schema} = Licet.Schema.parse(@sample)
    assert schema.expiration
    assert {:ok, again} = Licet.Schema.parse(Licet.Schema.to_zed(schema))
    assert again.definitions == schema.definitions
  end

  test "reports line and column for syntax and validation errors" do
    assert {:error, %{reason: :invalid_schema, details: %{line: line}}} =
             Licet.Schema.parse("definition user {")

    assert line >= 1
    assert {:error, %{message: "caveats are not supported"}} = Licet.Schema.parse("caveat foo {}")

    assert {:error, %{message: message}} =
             Licet.Schema.parse("definition user {}\ndefinition user {}")

    assert message =~ "duplicated"

    assert {:error, %{reason: :invalid_schema}} =
             Licet.Schema.parse("definition document {\n  permission view = missing\n}")

    assert {:error, %{reason: :invalid_schema}} =
             Licet.Schema.parse("definition document {\n  permission view = view\n}")

    assert {:error, %{message: message}} =
             Licet.Schema.parse(
               "definition user {}\ndefinition document {\n  relation viewer: user with expiration\n}"
             )

    assert message =~ "use expiration"
    assert {:error, _} = Licet.Schema.parse(:nope)
    assert {:error, %{message: "unexpected character !"}} = Licet.Schema.parse("!")

    assert {:error, %{reason: :invalid_schema, details: %{line: 1}}} =
             Licet.Schema.parse(String.duplicate("definition a {} ", 5_001))

    expiration =
      "use expiration\ndefinition user {}\ndefinition document {\n  relation viewer: user with "

    assert {:error, %{message: "caveats are not supported"}} =
             Licet.Schema.parse(expiration <> "expiration and testcaveat\n}")

    assert {:error, %{message: "expected expiration"}} =
             Licet.Schema.parse(expiration <> "| user\n}")

    assert {:error, _} = Licet.Schema.parse("definition user { relation")
    assert {:error, _} = Licet.Schema.parse("definition user { permission view =")
    assert {:error, _} = Licet.Schema.parse("definition")
    assert {:error, _} = Licet.Schema.parse("use nope")
    assert {:error, _} = Licet.Schema.parse("use expiration\nuse expiration\ndefinition user {}")
    assert {:error, _} = Licet.Schema.parse("definition user {}\nnope")
    assert {:error, _} = Licet.Schema.parse("definition {")
    assert {:error, _} = Licet.Schema.parse("definition user { relation }")
    assert {:error, %{message: message}} = Licet.Schema.parse("definition user { nope }")
    assert message =~ "relation, permission, or }"
    assert {:error, _} = Licet.Schema.parse("definition user { relation owner user }")
    assert {:error, _} = Licet.Schema.parse("definition user { relation owner")

    assert {:error, _} =
             Licet.Schema.parse(
               "definition user {}\ndefinition document {\n  relation viewer: user#\n}"
             )

    assert {:error, _} =
             Licet.Schema.parse(
               "definition user {}\ndefinition document {\n  relation viewer: user with nope\n}"
             )

    assert {:error, _} =
             Licet.Schema.parse(
               "definition user {}\ndefinition document {\n  permission view =\n}"
             )

    assert {:error, _} =
             Licet.Schema.parse(
               "definition user {}\ndefinition document {\n  permission view = (\n}"
             )

    assert {:error, _} = Licet.Schema.parse("definition Ab {}\n")

    assert {:error, _} =
             Licet.Schema.parse(
               "definition user {}\ndefinition document {\n  relation viewer: user | missing\n}"
             )

    assert {:error, _} =
             Licet.Schema.parse(
               "definition user {}\ndefinition document {\n  relation Owner: user\n}"
             )

    assert {:error, _} =
             Licet.Schema.parse(
               "definition user {}\ndefinition document {\n  relation viewer: user | user#Member\n}"
             )

    assert {:error, _} =
             Licet.Schema.parse(
               "definition user {}\ndefinition document {\n  permission View = viewer\n  relation viewer: user\n}"
             )

    assert {:error, _} =
             Licet.Schema.parse(
               "definition user {}\ndefinition document {\n  relation viewer: user\n  relation viewer: user\n}"
             )

    assert {:error, _} =
             Licet.Schema.parse(
               "definition user {}\ndefinition document {\n  relation viewer: user\n  permission view = viewer\n  permission view = viewer\n}"
             )

    assert {:error, _} =
             Licet.Schema.parse(
               "definition user {}\ndefinition document {\n  relation viewer: user\n  permission view = missing->view\n}"
             )

    assert {:error, _} =
             Licet.Schema.parse(
               "definition user {}\ndefinition document {\n  relation parent: document\n  permission view = parent->missing\n}"
             )

    nested = """
    definition user {}
    definition document {
      relation owner: user
      relation viewer: user
      relation parent: document
      permission edit = owner
      permission view = parent->parent->view
      permission both = edit & (owner + viewer)
      permission hop = parent->(owner + viewer)
    }
    """

    assert {:ok, nested_schema} = Licet.Schema.parse(nested)
    assert Licet.Schema.to_zed(nested_schema) =~ "("
  end

  test "rejects arrows that do not start at a relation" do
    arrow = """
    definition user {}
    definition document {
      permission edit = owner
      relation parent: document
      relation owner: user
      permission view = parent->edit->owner
      permission broken = missing->parent->owner
      permission mixed = (owner + viewer)->edit
    }
    """

    assert {:error, %{message: message}} = Licet.Schema.parse(arrow)
    assert message =~ "relation"
  end

  test "diffs unsafe schema edits" do
    {:ok, old} = Licet.Schema.parse(@sample)
    {:ok, newer} = Licet.Schema.parse("definition user {}")
    changes = Diff.changes(old, newer)
    assert "document" in changes.removed_definitions
    assert changes.dropped_expiration
    assert Diff.changes(nil, newer).removed_definitions == []
  end

  test "rejects incomplete relationship text" do
    assert {:error, %{reason: :invalid_relationship}} =
             Licet.Relationship.parse("document:1#owner")

    assert {:error, _} = Licet.Relationship.parse("document:1#owner@user#member")
    assert {:error, _} = Licet.Relationship.parse("document:1#owner@nocolon")
  end

  property "relationship text round-trips" do
    check all(rel <- relationship(), max_runs: 20) do
      {:ok, parsed} = Licet.Relationship.parse(Licet.Relationship.to_string(rel))
      assert parsed.resource_type == rel.resource_type
      assert parsed.subject_id == rel.subject_id
    end
  end

  test "rejects bad relationships, tokens, and pages" do
    assert {:error, %{reason: :invalid_relationship}} = Licet.Relationship.parse("nope")
    assert {:error, %{reason: :invalid_relationship}} = Licet.Relationship.parse(1)
    assert {:ok, "user", "*", ""} = Licet.Relationship.parse_object("user:*")
    assert {:ok, "team", "eng", "member"} = Licet.Relationship.parse_object("team:eng#member")
    assert {:error, %{reason: :invalid_relationship}} = Licet.Relationship.parse_object(1)
    assert {:error, %{reason: :invalid_relationship}} = Licet.Relationship.parse_object("nope")

    assert {:error, %{reason: :invalid_relationship}} =
             Licet.Relationship.parse_object("user:ada#")

    assert {:error, _} = Licet.Relationship.parse("document:1#viewer@user:ada[expiration:nope]")
    assert {:error, _} = Licet.Relationship.parse("document:1#viewer")
    refute Licet.Relationship.valid_type?(1)

    rel = %Licet.Relationship{
      resource_type: "document",
      resource_id: "1",
      relation: "viewer",
      subject_type: "team",
      subject_id: "eng",
      subject_relation: "member",
      expires_at: ~U[2030-01-01 00:00:00Z]
    }

    assert Licet.Relationship.to_string(rel) =~ "[expiration:"

    assert {:error, :token_invalid} =
             Licet.Token.decode("v1." <> Base.url_encode64("{}", padding: false))

    subject_cursor =
      "v1." <> Base.url_encode64(Jason.encode!(["user", "ada", "member"]), padding: false)

    assert {:ok, [{"user", "bob", ""}, {"user", "cara", "member"}], nil} =
             Licet.Page.slice(
               [{"user", "bob", ""}, {"user", "cara", "member"}],
               subject_cursor,
               10
             )

    other_cursor = "v1." <> Base.url_encode64("1", padding: false)
    assert {:ok, [2], _} = Licet.Page.slice([2, 0], other_cursor, 1)
    assert {:error, :token_invalid} = Licet.Token.decode("nope")
    assert {:error, %{reason: :invalid_filter}} = Licet.Page.slice(["a"], "bad", 1)
    token = Licet.Token.encode(%{xid: "10", snapshot: "10:10:", at: ~U[2026-01-01 00:00:00Z]})
    assert {:ok, %{xid: "10"}} = Licet.Token.decode(token)
    assert {:ok, ["a"], cursor} = Licet.Page.slice(["b", "a", "c"], nil, 1)
    assert {:ok, ["b", "c"], nil} = Licet.Page.slice(["b", "a", "c"], cursor, 10)
  end

  defp relationship do
    gen all(
          type <- member_of(["user", "document", "docs/folder"]),
          id <- member_of(["ada", "bob", "1"]),
          relation <- member_of(["owner", "viewer", "member"])
        ) do
      %Licet.Relationship{
        resource_type: "document",
        resource_id: "1",
        relation: "viewer",
        subject_type: type,
        subject_id: id,
        subject_relation: if(relation == "member", do: "member", else: ""),
        expires_at: nil
      }
    end
  end
end
