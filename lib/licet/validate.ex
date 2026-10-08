defmodule Licet.Validate do
  @moduledoc """
  Runs a SpiceDB validation file against the Licet engine.

  The file contains `schema`, `relationships`, and `assertions`.
  """

  alias Licet.Engine
  alias Licet.Error
  alias Licet.Reader.Memory
  alias Licet.Relationship
  alias Licet.Schema

  @type failure :: %{assertion: String.t(), expected: :allowed | :denied, got: term()}

  @doc """
  Validates the YAML file at `path`.
  """
  @spec run_file(Path.t()) :: :ok | {:error, Error.t() | [failure()]}
  def run_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, source} ->
        run(source)

      {:error, reason} ->
        {:error, Error.new(:invalid_schema, "cannot read #{path}: #{inspect(reason)}")}
    end
  end

  @doc """
  Validates YAML text.
  """
  @spec run(String.t()) :: :ok | {:error, Error.t() | [failure()]}
  def run(source) when is_binary(source) do
    data = YamlElixir.read_from_string!(source, atoms: false)

    with {:ok, schema} <- Schema.parse(Map.get(data, "schema", "")),
         {:ok, tuples} <- relationships(Map.get(data, "relationships", "")) do
      failures = check_all(schema, tuples, Map.get(data, "assertions", %{}))
      if failures == [], do: :ok, else: {:error, failures}
    end
  end

  defp relationships(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "//")))
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Relationship.parse(line) do
        {:ok, rel} -> {:cont, {:ok, [rel | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp check_all(schema, tuples, assertions) do
    reader = %Memory{tuples: tuples}
    revision = %{snapshot: "0:0:", own_xid: "", at: ~U[2099-01-01 00:00:00Z]}

    true_failures =
      check_group(schema, reader, revision, assertions["assertTrue"] || [], :allowed)

    false_failures =
      check_group(schema, reader, revision, assertions["assertFalse"] || [], :denied)

    true_failures ++ false_failures
  end

  defp check_group(schema, reader, revision, lines, expected) do
    Enum.flat_map(lines, &check_line(schema, reader, revision, &1, expected))
  end

  defp check_line(schema, reader, revision, line, expected) do
    case Relationship.parse(line) do
      {:ok, rel} ->
        resource = %{type: rel.resource_type, id: rel.resource_id, relation: ""}
        subject = %{type: rel.subject_type, id: rel.subject_id, relation: rel.subject_relation}

        case Engine.check(schema, reader, revision, resource, rel.relation, subject,
               timeout: 5_000,
               parallel: nil
             ) do
          {:ok, ^expected} -> []
          other -> [%{assertion: line, expected: expected, got: other}]
        end

      {:error, error} ->
        [%{assertion: line, expected: expected, got: {:error, error}}]
    end
  end
end
