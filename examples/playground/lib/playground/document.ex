defmodule Playground.Document do
  @moduledoc """
  The four editors of the playground and the validation YAML they make up.

  This is the file [play.authzed.com](https://play.authzed.com) exports and
  `zed validate` reads. `schema` and `relationships` are block strings.
  `assertions` and `validation` are kept as the YAML text the user edits, so
  comments and ordering survive a round trip through the editor.
  """

  defstruct schema: "", relationships: "", assertions: "", validation: ""

  @type t :: %__MODULE__{
          schema: String.t(),
          relationships: String.t(),
          assertions: String.t(),
          validation: String.t()
        }

  @plain_key ~r/^[A-Za-z0-9_\/:#.*-]+$/

  @doc """
  A small document schema with groups, folders, and a banned list.
  """
  @spec example() :: t()
  def example do
    %__MODULE__{
      schema: """
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
      }\
      """,
      relationships: """
      // Anne edits the readme; engineering can read it through its folder.
      document:readme#editor@user:anne
      document:readme#parent@folder:handbook
      folder:handbook#viewer@group:engineering#member
      group:engineering#member@user:beth
      group:engineering#member@group:platform#member
      group:platform#member@user:carl

      // The changelog is public, except for Dan.
      document:changelog#viewer@user:*
      document:changelog#banned@user:dan\
      """,
      assertions: """
      assertTrue:
        - document:readme#view@user:anne
        - document:readme#view@user:carl
        - document:changelog#view@user:erin
      assertFalse:
        - document:readme#edit@user:beth
        - document:changelog#view@user:dan\
      """,
      validation: """
      document:readme#view:
        - "[group:engineering#member] is <folder:handbook#viewer>"
        - "[group:platform#member] is <group:engineering#member>"
        - "[user:anne] is <document:readme#editor>"
        - "[user:beth] is <group:engineering#member>"
        - "[user:carl] is <group:platform#member>"
      document:changelog#view:
        - "[user:* - {user:dan}] is <document:changelog#viewer>"\
      """
    }
  end

  @doc """
  Reads a validation file. Sections the playground does not edit are dropped.
  """
  @spec from_yaml(String.t()) :: {:ok, t()} | {:error, String.t()}
  def from_yaml(source) when is_binary(source) do
    case YamlElixir.read_from_string(source, atoms: false) do
      {:ok, data} when is_map(data) -> from_map(data)
      {:ok, _other} -> {:error, "a validation file is a YAML map"}
      {:error, error} -> {:error, "invalid YAML: " <> Exception.message(error)}
    end
  end

  defp from_map(data) do
    with {:ok, schema} <- text(data, "schema"),
         {:ok, relationships} <- text(data, "relationships"),
         {:ok, assertions} <- assertions(data["assertions"]),
         {:ok, validation} <- validation(data["validation"]) do
      {:ok,
       %__MODULE__{
         schema: schema,
         relationships: relationships,
         assertions: assertions,
         validation: validation
       }}
    end
  end

  @doc """
  Writes the document as one validation file.
  """
  @spec to_yaml(t()) :: String.t()
  def to_yaml(%__MODULE__{} = document) do
    [
      block("schema", document.schema),
      block("relationships", document.relationships),
      section("assertions", document.assertions),
      section("validation", document.validation)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  defp text(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, ""}
      value when is_binary(value) -> {:ok, String.trim_trailing(value)}
      _other -> {:error, "#{key} must be a block of text"}
    end
  end

  defp assertions(nil), do: {:ok, ""}

  defp assertions(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _lines} -> key != "assertTrue" end)
    |> Enum.map(fn {key, lines} -> list(key, lines) end)
    |> join_sections()
  end

  defp assertions(_other), do: {:error, "assertions must be a map"}

  defp validation(nil), do: {:ok, ""}

  defp validation(value) when is_map(value) do
    value
    |> Enum.sort()
    |> Enum.map(fn {key, lines} -> list(key, lines) end)
    |> join_sections()
  end

  defp validation(_other), do: {:error, "validation must be a map"}

  defp list(key, nil), do: list(key, [])
  defp list(key, []), do: {:ok, key(key) <> ": []"}

  defp list(key, lines) when is_list(lines) do
    if Enum.all?(lines, &is_binary/1),
      do: {:ok, key(key) <> ":\n" <> Enum.map_join(lines, "\n", &("  - " <> quoted(&1)))},
      else: {:error, "#{key} must list strings"}
  end

  defp list(key, _other), do: {:error, "#{key} must be a list"}

  defp join_sections(results) do
    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map_join(results, "\n", fn {:ok, text} -> text end)}
      error -> error
    end
  end

  defp key(key) do
    if Regex.match?(@plain_key, key), do: key, else: quoted(key)
  end

  defp quoted(text), do: "'" <> String.replace(text, "'", "''") <> "'"

  defp block(key, text) do
    trimmed = String.trim_trailing(text)
    header = if String.match?(trimmed, ~r/\A\s/), do: key <> ": |2-\n", else: key <> ": |-\n"
    header <> indent(trimmed) <> "\n"
  end

  defp section(_key, text) when text in ["", nil], do: nil

  defp section(key, text) do
    key <> ":\n" <> indent(String.trim_trailing(text)) <> "\n"
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "  " <> line
    end)
  end
end
