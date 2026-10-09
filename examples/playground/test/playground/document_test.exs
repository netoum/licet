defmodule Playground.DocumentTest do
  use ExUnit.Case, async: true

  alias Playground.Document

  test "the example validates" do
    assert Licet.Validate.run(Document.to_yaml(Document.example())) == :ok
  end

  test "the example's expected relations are what Licet computes" do
    example = Document.example()
    {:ok, computed} = Licet.Validate.expected_relations(Document.to_yaml(example))

    assert YamlElixir.read_from_string!(computed) ==
             YamlElixir.read_from_string!(example.validation)
  end

  test "a document survives export and import" do
    example = Document.example()
    assert {:ok, imported} = Document.from_yaml(Document.to_yaml(example))

    assert imported.schema == example.schema
    assert imported.relationships == example.relationships

    assert YamlElixir.read_from_string!(imported.assertions) ==
             YamlElixir.read_from_string!(example.assertions)

    assert YamlElixir.read_from_string!(imported.validation) ==
             YamlElixir.read_from_string!(example.validation)
  end

  test "imports quote odd keys and lines, and keep empty sections" do
    source = """
    schema: "  definition user {}"
    assertions:
      assertFalse: ["it's"]
    validation:
      "a key with spaces": []
      document:1#view:
    """

    assert {:ok, document} = Document.from_yaml(source)
    assert document.assertions == "assertFalse:\n  - 'it''s'"
    assert document.validation == "'a key with spaces': []\ndocument:1#view: []"
    assert Document.to_yaml(document) =~ "schema: |2-\n    definition user {}"
    assert {:ok, ^document} = Document.from_yaml(Document.to_yaml(document))
  end

  test "rejects files that are not playground files" do
    for {source, message} <- [
          {"- a list", "a validation file is a YAML map"},
          {"schema: [", "invalid YAML"},
          {"schema: [1]", "schema must be a block of text"},
          {"assertions: 1", "assertions must be a map"},
          {"assertions:\n  assertTrue: 1", "assertTrue must be a list"},
          {"assertions:\n  assertTrue: [[1]]", "assertTrue must list strings"},
          {"validation: 1", "validation must be a map"}
        ] do
      assert {:error, got} = Document.from_yaml(source)
      assert got =~ message
    end
  end
end
