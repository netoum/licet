defmodule Licet.Validate do
  @moduledoc """
  Runs a SpiceDB validation file against the Licet engine.

  The file is the YAML that [play.authzed.com](https://play.authzed.com) exports
  and `zed validate` reads:

  * `schema`, the `.zed` text
  * `relationships`, one relationship per line, with `//` comments
  * `assertions`, with `assertTrue` and `assertFalse` lists of checks
  * `validation`, the expected relations: for each `resource#permission`, every
    subject and the relations that hold it, as `[user:tom] is <document:1#viewer>`

  Checks run at the current time, so a relationship whose `[expiration:...]`
  has passed does not count. Relationships are held in memory; nothing is
  written to Postgres.
  """

  alias Licet.Engine
  alias Licet.Error
  alias Licet.Reader.Memory
  alias Licet.Relationship
  alias Licet.Schema
  alias Licet.Validate.Expected

  defstruct schema: nil, relationships: [], assert_true: [], assert_false: [], validation: nil

  @type t :: %__MODULE__{
          schema: Schema.t(),
          relationships: [Relationship.t()],
          assert_true: [String.t()],
          assert_false: [String.t()],
          validation: expected() | nil
        }

  @typedoc """
  The parsed `validation` section: each `{type, id, relation}` resource with
  its expected subject lines.
  """
  @type expected :: [{{String.t(), String.t(), String.t()}, [map()]}]

  @type failure ::
          %{assertion: String.t(), expected: :allowed | :denied, got: term()}
          | %{relation: String.t(), message: String.t()}

  @check_opts [timeout: 5_000, parallel: nil]

  @doc """
  Validates the YAML file at `path`.
  """
  @spec run_file(Path.t()) :: :ok | {:error, Error.t() | [failure()]}
  def run_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, source} ->
        run(source)

      {:error, reason} ->
        {:error, invalid("cannot read #{path}: #{:file.format_error(reason)}")}
    end
  end

  @doc """
  Validates YAML text: every assertion, then every expected relation.
  """
  @spec run(String.t()) :: :ok | {:error, Error.t() | [failure()]}
  def run(source) when is_binary(source) do
    with {:ok, file} <- parse(source) do
      case assertion_failures(file) ++ expected_failures(file) do
        [] -> :ok
        failures -> {:error, failures}
      end
    end
  end

  @doc """
  Parses YAML text into a schema, relationships, assertions, and expected relations.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def parse(source) when is_binary(source) do
    with {:ok, data} <- read_yaml(source),
         {:ok, schema} <- Schema.parse(data["schema"] || ""),
         {:ok, relationships} <- relationships(data["relationships"] || ""),
         {:ok, assertions} <- section(data, "assertions"),
         {:ok, validation} <- validation(data["validation"]) do
      {:ok,
       %__MODULE__{
         schema: schema,
         relationships: relationships,
         assert_true: assertions["assertTrue"] || [],
         assert_false: assertions["assertFalse"] || [],
         validation: validation
       }}
    end
  end

  @doc """
  Recomputes the `validation` section for the keys it already lists, in the
  same YAML that SpiceDB's playground writes when it updates expected relations.
  """
  @spec expected_relations(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def expected_relations(source) when is_binary(source) do
    with {:ok, file} <- parse(source),
         {:ok, generated} <-
           Expected.generate(file.schema, reader(file), revision(), file.validation || []) do
      {:ok, Expected.format(generated)}
    end
  end

  defp read_yaml(source) do
    case YamlElixir.read_from_string(source, atoms: false) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _other} -> {:error, invalid("a validation file is a YAML map")}
      {:error, error} -> {:error, invalid("invalid YAML: #{Exception.message(error)}")}
    end
  end

  defp section(data, key) do
    case data[key] do
      nil -> {:ok, %{}}
      value when is_map(value) -> {:ok, value}
      _other -> {:error, invalid("#{key} must be a map")}
    end
  end

  defp validation(nil), do: {:ok, nil}

  defp validation(value) when is_map(value) do
    with true <- Enum.all?(value, fn {_key, lines} -> is_nil(lines) or is_list(lines) end),
         {:ok, parsed} <-
           Expected.parse(Map.new(value, fn {key, lines} -> {key, lines || []} end)) do
      {:ok, parsed}
    else
      false -> {:error, invalid("each validation entry must be a list")}
      {:error, message} -> {:error, invalid(message)}
    end
  end

  defp validation(_other), do: {:error, invalid("validation must be a map")}

  defp relationships(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "//")))
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Relationship.parse(line) do
        {:ok, rel} -> {:cont, {:ok, [rel | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> then(fn
      {:ok, rels} -> {:ok, Enum.reverse(rels)}
      error -> error
    end)
  end

  defp relationships(_other), do: {:error, invalid("relationships must be a block of text")}

  defp assertion_failures(file) do
    reader = reader(file)
    revision = revision()

    Enum.flat_map(file.assert_true, &check_line(file.schema, reader, revision, &1, :allowed)) ++
      Enum.flat_map(file.assert_false, &check_line(file.schema, reader, revision, &1, :denied))
  end

  defp check_line(schema, reader, revision, line, expected) do
    with {:ok, rel} <- Relationship.parse(line),
         resource = %{type: rel.resource_type, id: rel.resource_id, relation: ""},
         subject = %{type: rel.subject_type, id: rel.subject_id, relation: rel.subject_relation},
         {:ok, ^expected} <-
           Engine.check(schema, reader, revision, resource, rel.relation, subject, @check_opts) do
      []
    else
      other -> [%{assertion: line, expected: expected, got: other}]
    end
  end

  defp expected_failures(%{validation: nil}), do: []

  defp expected_failures(file) do
    Expected.failures(file.schema, reader(file), revision(), file.validation)
  end

  defp reader(file), do: %Memory{tuples: file.relationships}

  defp revision, do: %{snapshot: "0:0:", own_xid: "", at: DateTime.utc_now()}

  defp invalid(message), do: Error.new(:invalid_validation_file, message)
end
