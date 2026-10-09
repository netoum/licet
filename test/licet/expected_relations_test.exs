defmodule Licet.ExpectedRelationsTest do
  @moduledoc """
  The expected-relations fixtures from SpiceDB's
  `pkg/development/wasm/operations_test.go`: the first validation error and the
  regenerated `validation` YAML must match SpiceDB byte for byte.
  """
  use ExUnit.Case, async: true

  alias Licet.Engine
  alias Licet.Engine.Membership
  alias Licet.Reader.Memory
  alias Licet.Relationship
  alias Licet.Validate

  @view_schema """
  definition user {}
  definition document {
    relation writer: user
    relation viewer: user
    permission view = viewer + writer
  }
  """

  @wildcard_schema """
  definition user {}
  definition document {
    relation writer: user
    relation viewer: user | user:*
    permission view = viewer + writer
  }
  """

  @banned_schema """
  definition user {}
  definition document {
    relation banned: user
    relation viewer: user | user:*
    permission view = viewer - banned
  }
  """

  @fixtures [
    %{
      name: "missing subject",
      schema: @view_schema,
      relationships: ["document:somedoc#writer@user:jimmy"],
      validation: ~s("document:somedoc#view":),
      error:
        "For object and permission/relation `document:somedoc#view`, " <>
          "subject `user:jimmy` found but not listed in expected subjects",
      yaml: """
      document:somedoc#view:
          - '[user:jimmy] is <document:somedoc#writer>'
      """
    },
    %{
      name: "extra subject",
      schema: @view_schema,
      relationships: ["document:somedoc#writer@user:jimmy"],
      validation: """
      "document:somedoc#view":
      - "[user:jimmy] is <document:somedoc#writer>"
      - "[user:jake] is <document:somedoc#viewer>"
      """,
      error:
        "For object and permission/relation `document:somedoc#view`, missing expected subject `user:jake`",
      yaml: """
      document:somedoc#view:
          - '[user:jimmy] is <document:somedoc#writer>'
      """
    },
    %{
      name: "different relations",
      schema: @view_schema,
      relationships: ["document:somedoc#writer@user:jimmy"],
      validation: """
      "document:somedoc#view":
      - "[user:jimmy] is <document:somedoc#viewer>"
      """,
      error:
        "For object and permission/relation `document:somedoc#view`, found different relationships for " <>
          "subject `user:jimmy`: Specified: `<document:somedoc#viewer>`, Computed: `<document:somedoc#writer>`",
      yaml: """
      document:somedoc#view:
          - '[user:jimmy] is <document:somedoc#writer>'
      """
    },
    %{
      name: "multipath",
      schema: @view_schema,
      relationships: ["document:somedoc#writer@user:jimmy", "document:somedoc#viewer@user:jimmy"],
      validation: """
      "document:somedoc#view":
      - "[user:jimmy] is <document:somedoc#writer>/<document:somedoc#viewer>"
      """,
      error: nil,
      yaml: """
      document:somedoc#view:
          - '[user:jimmy] is <document:somedoc#viewer>/<document:somedoc#writer>'
      """
    },
    %{
      name: "multipath missing relationship",
      schema: @view_schema,
      relationships: ["document:somedoc#writer@user:jimmy", "document:somedoc#viewer@user:jimmy"],
      validation: """
      "document:somedoc#view":
      - "[user:jimmy] is <document:somedoc#writer>"
      """,
      error:
        "For object and permission/relation `document:somedoc#view`, found different relationships for " <>
          "subject `user:jimmy`: Specified: `<document:somedoc#writer>`, " <>
          "Computed: `<document:somedoc#viewer>/<document:somedoc#writer>`",
      yaml: """
      document:somedoc#view:
          - '[user:jimmy] is <document:somedoc#viewer>/<document:somedoc#writer>'
      """
    },
    %{
      name: "wildcard relationship",
      schema: @wildcard_schema,
      relationships: ["document:somedoc#writer@user:jimmy", "document:somedoc#viewer@user:*"],
      validation: """
      "document:somedoc#view":
      - "[user:*] is <document:somedoc#viewer>"
      - "[user:jimmy] is <document:somedoc#writer>"
      """,
      error: nil,
      yaml: """
      document:somedoc#view:
          - '[user:*] is <document:somedoc#viewer>'
          - '[user:jimmy] is <document:somedoc#writer>'
      """
    },
    %{
      name: "wildcard exclusion",
      schema: @banned_schema,
      relationships: ["document:somedoc#banned@user:jimmy", "document:somedoc#viewer@user:*"],
      validation: """
      "document:somedoc#view":
      - "[user:* - {user:jimmy}] is <document:somedoc#viewer>"
      """,
      error: nil,
      yaml: """
      document:somedoc#view:
          - '[user:* - {user:jimmy}] is <document:somedoc#viewer>'
      """
    },
    %{
      name: "wildcard multiple exclusion",
      schema: @banned_schema,
      relationships: [
        "document:somedoc#banned@user:jimmy",
        "document:somedoc#banned@user:fred",
        "document:somedoc#viewer@user:*"
      ],
      validation: """
      "document:somedoc#view":
      - "[user:* - {user:fred, user:jimmy}] is <document:somedoc#viewer>"
      """,
      error: nil,
      yaml: """
      document:somedoc#view:
          - '[user:* - {user:fred, user:jimmy}] is <document:somedoc#viewer>'
      """
    },
    %{
      name: "wildcard exclusion under intersection",
      schema: """
      definition user {}
      definition document {
        relation banned: user
        relation viewer: user | user:*
        relation other: user
        permission view = (viewer - banned) & (viewer - other)
      }
      """,
      relationships: [
        "document:somedoc#other@user:sarah",
        "document:somedoc#banned@user:jimmy",
        "document:somedoc#viewer@user:*"
      ],
      validation: """
      "document:somedoc#view":
      - "[user:* - {user:jimmy, user:sarah}] is <document:somedoc#viewer>"
      """,
      error: nil,
      yaml: """
      document:somedoc#view:
          - '[user:* - {user:jimmy, user:sarah}] is <document:somedoc#viewer>'
      """
    },
    %{
      name: "nil handling",
      schema: """
      definition user {}
      definition document {
        relation viewer: user
        permission view = viewer
        permission empty = nil
      }
      """,
      relationships: ["document:somedoc#viewer@user:jill", "document:somedoc#viewer@user:tom"],
      validation: """
      "document:somedoc#view":
      - "[user:jill] is <document:somedoc#viewer>"
      - "[user:tom] is <document:somedoc#viewer>"
      "document:somedoc#empty": []
      """,
      error: nil,
      yaml:
        "document:somedoc#empty: []\ndocument:somedoc#view:\n" <>
          "    - '[user:jill] is <document:somedoc#viewer>'\n    - '[user:tom] is <document:somedoc#viewer>'\n"
    },
    %{
      name: "no expected subject or relation",
      schema: """
      definition user {}
      definition document {
        relation viewer: user
        permission view = viewer
      }
      """,
      relationships: ["document:somedoc#viewer@user:jill", "document:somedoc#viewer@user:tom"],
      validation: """
      "document:somedoc#view":
      - "is <document:somedoc#viewer>"
      - "[user:tom] is "
      """,
      error:
        "For object and permission/relation `document:somedoc#view`, " <>
          "no expected subject specified in `is <document:somedoc#viewer>`",
      yaml:
        "document:somedoc#view:\n" <>
          "    - '[user:jill] is <document:somedoc#viewer>'\n    - '[user:tom] is <document:somedoc#viewer>'\n"
    }
  ]

  for fixture <- @fixtures do
    @fixture fixture
    test "#{fixture.name}" do
      source = source(@fixture)

      assert Validate.expected_relations(source) == {:ok, @fixture.yaml}

      if @fixture.error do
        assert {:error, [%{message: message} | _rest]} = Validate.run(source)
        assert message == @fixture.error
      end
    end
  end

  test "parse error in a validation subject" do
    source =
      source(%{
        schema: @view_schema,
        relationships: [],
        validation: ~s(document:somedoc#view: ["[user] is <document:somedoc#writer>"])
      })

    assert {:error, %Licet.Error{reason: :invalid_validation_file, message: message}} =
             Validate.run(source)

    assert message == "invalid subject: `user`: invalid subject ONR: user"
  end

  test "parse error in a validation resource" do
    source =
      source(%{
        schema: @view_schema,
        relationships: [],
        validation: ~s(document:somedoc#view: ["[user:jimmy] is <document:som>"])
      })

    assert {:error, %Licet.Error{message: message}} = Validate.run(source)
    assert message == "invalid resource and relation: `document:som`: invalid ONR: document:som"
  end

  test "parse errors in keys, exclusions and entries" do
    for {validation, message} <- [
          {~s(document:somedoc: []),
           "invalid resource and relation: `document:somedoc`: invalid ONR: document:somedoc"},
          {~s(document:somedoc#view: ["[user:* - {bad}] is <document:somedoc#viewer>"]),
           "invalid subject: `bad`: invalid subject ONR: bad"},
          {~s(document:somedoc#view: ["[user:a b] is <document:somedoc#viewer>"]),
           "invalid subject: `user:a b`"},
          {~s(document:somedoc#view: ["[user:a!] is <document:somedoc#viewer>"]),
           "invalid subject: `user:a!`: invalid subject ONR: user:a!"},
          {~s(document:somedoc#view: [1]), "expected relation must be a string, got 1"}
        ] do
      source = source(%{schema: @view_schema, relationships: [], validation: validation})
      assert {:error, %Licet.Error{message: ^message}} = Validate.run(source)
    end
  end

  test "exclusion and caveat mismatches" do
    prefix = "For object and permission/relation `document:somedoc#view`, "

    cases = [
      {@banned_schema, ["document:somedoc#viewer@user:*", "document:somedoc#banned@user:jimmy"],
       ~s("[user:*] is <document:somedoc#viewer>"),
       "found different excluded subjects for subject `user:*`: Specified: ``, Computed: `<user:jimmy>`"},
      {@view_schema, ["document:somedoc#viewer@user:jimmy"],
       ~s("[user:jimmy - {user:fred}] is <document:somedoc#viewer>"),
       "found unexpected excluded subjects"},
      {@view_schema, ["document:somedoc#viewer@user:jimmy"],
       ~s("[user:jimmy[...]] is <document:somedoc#viewer>"), "found caveat mismatch"}
    ]

    for {schema, relationships, line, message} <- cases do
      source =
        source(%{
          schema: schema,
          relationships: relationships,
          validation: "document:somedoc#view: [#{line}]"
        })

      expected = prefix <> message
      assert {:error, [%{message: ^expected}]} = Validate.run(source)
    end
  end

  test "caveated exclusions keep their marker" do
    source =
      source(%{
        schema: @banned_schema,
        relationships: ["document:somedoc#viewer@user:*", "document:somedoc#banned@user:jimmy"],
        validation:
          ~s(document:somedoc#view: ["[user:* - {user:jimmy[...]}] is <document:somedoc#viewer>"])
      })

    assert {:error, [%{message: message}]} = Validate.run(source)
    assert message =~ "Specified: `<user:jimmy[...]>`, Computed: `<user:jimmy>`"
  end

  test "engine errors are reported per key" do
    source =
      source(%{
        schema: @view_schema,
        relationships: [],
        validation: ~s(document:somedoc#missing: [])
      })

    assert {:error, [%{relation: "document:somedoc#missing", message: message}]} =
             Validate.run(source)

    assert message =~ "missing"
    assert {:error, %Licet.Error{}} = Validate.expected_relations(source)
  end

  test "wildcards keep shared exclusions through a union and concrete subjects through an intersection" do
    schema = """
    definition user {}
    definition document {
      relation banned: user
      relation viewer: user | user:*
      relation editor: user | user:*
      permission either = (viewer - banned) + (editor - banned)
      permission both = viewer & editor
    }
    """

    source =
      source(%{
        schema: schema,
        relationships: [
          "document:somedoc#viewer@user:*",
          "document:somedoc#editor@user:*",
          "document:somedoc#banned@user:jimmy",
          "document:somedoc#viewer@user:tom",
          "document:somedoc#editor@user:tom"
        ],
        validation: "document:somedoc#either: []\ndocument:somedoc#both: []"
      })

    assert Validate.expected_relations(source) ==
             {:ok,
              """
              document:somedoc#both:
                  - '[user:*] is <document:somedoc#editor>/<document:somedoc#viewer>'
                  - '[user:tom] is <document:somedoc#editor>/<document:somedoc#viewer>'
              document:somedoc#either:
                  - '[user:* - {user:jimmy}] is <document:somedoc#editor>/<document:somedoc#viewer>'
                  - '[user:tom] is <document:somedoc#editor>/<document:somedoc#viewer>'
              """}
  end

  test "membership through arrows: no targets, undefined target relations, and errors" do
    {:ok, schema} =
      Licet.Schema.parse("""
      definition user {}
      definition folder {
        relation owner: user
      }
      definition document {
        relation parent: folder | user
        permission any_owner = parent->owner
        permission all_owners = parent.all(owner)
      }
      """)

    revision = %{snapshot: "0:0:", own_xid: "", at: DateTime.utc_now()}
    empty = %Memory{tuples: []}

    assert {:ok, set} =
             Engine.membership(schema, empty, revision, "document", "1", "all_owners")

    assert Membership.to_list(set) == []

    {:ok, parent} = Relationship.parse("document:1#parent@folder:1")
    {:ok, user_parent} = Relationship.parse("document:1#parent@user:ada")
    reader = %Memory{tuples: [parent, user_parent]}

    for permission <- ["any_owner", "all_owners"] do
      assert {:ok, %Membership{}} =
               Engine.membership(schema, reader, revision, "document", "1", permission)

      assert {:error, %{reason: :depth_exceeded}} =
               Engine.membership(schema, reader, revision, "document", "1", permission,
                 max_depth: 0
               )
    end
  end

  test "malformed validation files" do
    assert Validate.run("") == :ok

    for {yaml, message} <- [
          {"- a list", "a validation file is a YAML map"},
          {"schema: [", "invalid YAML"},
          {"assertions: 1", "assertions must be a map"},
          {"validation: 1", "validation must be a map"},
          {"validation:\n  document:1#view: 1", "each validation entry must be a list"},
          {"relationships: [1]", "relationships must be a block of text"}
        ] do
      assert {:error, %Licet.Error{reason: :invalid_validation_file, message: got}} =
               Validate.run(yaml)

      assert got =~ message
    end
  end

  defp source(fixture) do
    relationships = Enum.map_join(fixture.relationships, "\n", &("  " <> &1))

    """
    schema: |
    #{indent(fixture.schema)}
    relationships: |
    #{relationships}
    validation:
    #{indent(fixture.validation)}
    """
  end

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
end
