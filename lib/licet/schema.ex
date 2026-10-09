defmodule Licet.Schema do
  @moduledoc """
  Parses schemas written in SpiceDB's schema language.

  A running instance parses its schema itself, from the `:schema` option or
  `Licet.write_schema/3`. Call `parse/1` directly to check a schema file, for
  example in a test or before a deploy.

  Licet supports definitions, relations, permissions, the operators `+`, `&`,
  `-`, and `->`, the arrow functions `.any()` and `.all()`, `nil`, wildcards,
  userset subjects such as `team#member`, and expiration. Caveats and `self`
  are rejected. [Schema language](zed.md) is the full reference.
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
  Parses and validates schema text.

  On success, returns a compiled schema. Its fields other than `:source` are
  internal. On failure, returns an `:invalid_schema` error whose `details`
  hold the `:line` and `:column` of the problem.

  ## Examples

      iex> {:ok, schema} =
      ...>   Licet.Schema.parse(\"""
      ...>   definition user {}
      ...>
      ...>   definition document {
      ...>     relation owner: user
      ...>     permission edit = owner
      ...>   }
      ...>   \""")
      iex> schema.definitions |> Map.keys() |> Enum.sort()
      ["document", "user"]

      iex> {:error, error} = Licet.Schema.parse("definition document {\\n  permission edit = owner\\n}")
      iex> error.reason
      :invalid_schema
      iex> error.details
      %{line: 2, column: 21}
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
  Prints a compiled schema as text.

  The result parses to the same definitions. Comments and formatting from the
  original text aren't preserved; definitions are sorted by name.

  ## Examples

      iex> {:ok, schema} = Licet.Schema.parse("definition user {}")
      iex> Licet.Schema.to_zed(schema)
      "definition user {\\n}"
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
  defp format_expr(:nil_expr), do: "nil"
  defp format_expr({:union, left, right} = expr), do: format_binary(expr, left, " + ", right)

  defp format_expr({:intersection, left, right} = expr),
    do: format_binary(expr, left, " & ", right)

  defp format_expr({:exclusion, left, right} = expr), do: format_binary(expr, left, " - ", right)
  defp format_expr({:arrow, left, right}), do: format_arrow(left) <> "->" <> format_primary(right)

  defp format_expr({:arrow_all, left, {:ref, name}}),
    do: format_arrow(left) <> ".all(" <> name <> ")"

  defp format_binary(expr, left, op, right) do
    format_operand(left, precedence(left) < precedence(expr)) <>
      op <> format_operand(right, precedence(right) <= precedence(expr))
  end

  defp format_operand(expr, true), do: "(" <> format_expr(expr) <> ")"
  defp format_operand(expr, false), do: format_expr(expr)

  defp precedence({:exclusion, _, _}), do: 1
  defp precedence({:intersection, _, _}), do: 2
  defp precedence({:union, _, _}), do: 3
  defp precedence(_expr), do: 4

  defp format_arrow(left) when is_binary(left), do: left
  defp format_arrow(left), do: "(" <> format_expr(left) <> ")"

  defp format_primary({:ref, name}), do: name
  defp format_primary(expr), do: "(" <> format_expr(expr) <> ")"
end
