defmodule Licet.Schema do
  @moduledoc """
  Parses and compiles a `.zed` schema.

  The supported subset is definitions, relations, permissions, the operators
  `+`, `&`, `-` and `->`, wildcards, subject relations such as `team#member`,
  `use expiration`, and `with expiration`. Comments starting with `//` are
  ignored. Caveats, `self`, and `.all` are rejected.
  """

  alias Licet.Schema.Parser
  alias Licet.Schema.Validator

  @type t :: %{
          definitions: map(),
          expiration: boolean(),
          source: String.t(),
          hash: String.t()
        }

  @doc """
  Parses schema source into a compiled schema.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, Licet.Error.t()}
  def parse(source) when is_binary(source) do
    case Parser.parse_schema(source) do
      {:ok, parts} -> finish(parts, source)
      {:error, message, line, column} -> {:error, syntax_error(message, line, column)}
    end
  end

  def parse(other) do
    {:error, Licet.Error.new(:invalid_schema, "schema must be a string, got #{inspect(other)}")}
  end

  @doc """
  Renders a compiled schema back to `.zed` text.

  Comments are not preserved. The result parses to the same definitions.
  """
  @spec to_zed(t()) :: String.t()
  def to_zed(%{definitions: definitions, expiration: expiration}) do
    body =
      definitions
      |> Map.values()
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n\n", &format_definition/1)

    if expiration, do: "use expiration\n\n" <> body, else: body
  end

  defp finish(parts, source) do
    case Validator.validate(parts, source) do
      {:ok, schema} -> {:ok, schema}
      {:error, errors} -> {:error, first_error(errors)}
    end
  end

  defp first_error([error | _rest]) do
    Licet.Error.new(:invalid_schema, error.message, %{line: error.line, column: error.column})
  end

  defp syntax_error(message, line, column) do
    Licet.Error.new(:invalid_schema, message, %{line: line, column: column})
  end

  defp format_definition(definition) do
    lines = relation_lines(definition) ++ permission_lines(definition)
    body = Enum.map_join(lines, "\n", &("  " <> &1))
    inner = if body == "", do: "", else: body <> "\n"
    "definition #{definition.name} {\n" <> inner <> "}"
  end

  defp relation_lines(definition) do
    definition.relations
    |> Map.values()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(&format_relation/1)
  end

  defp permission_lines(definition) do
    definition.permissions
    |> Enum.sort_by(fn {name, _expr} -> name end)
    |> Enum.map(fn {name, expr} -> "permission #{name} = #{format_expr(expr)}" end)
  end

  defp format_relation(relation) do
    subjects = Enum.map_join(relation.subjects, " | ", &format_subject/1)
    "relation #{relation.name}: #{subjects}"
  end

  defp format_subject(subject) do
    base =
      cond do
        subject.wildcard -> subject.type <> ":*"
        subject.relation -> subject.type <> "#" <> subject.relation
        true -> subject.type
      end

    if subject.expiration, do: base <> " with expiration", else: base
  end

  defp format_expr({:ref, name}), do: name
  defp format_expr({:union, left, right}), do: format_expr(left) <> " + " <> format_low(right)

  defp format_expr({:intersection, left, right}),
    do: format_low(left) <> " & " <> format_low(right)

  defp format_expr({:exclusion, left, right}), do: format_low(left) <> " - " <> format_low(right)
  defp format_expr({:arrow, left, right}), do: format_arrow(left) <> "->" <> format_primary(right)

  defp format_low({:union, _, _} = expr), do: "(" <> format_expr(expr) <> ")"
  defp format_low(expr), do: format_expr(expr)

  defp format_arrow(left) when is_binary(left), do: left
  defp format_arrow(left), do: "(" <> format_expr(left) <> ")"

  defp format_primary({:ref, name}), do: name
  defp format_primary(expr), do: "(" <> format_expr(expr) <> ")"
end
