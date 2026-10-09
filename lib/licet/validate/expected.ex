defmodule Licet.Validate.Expected do
  @moduledoc false

  alias Licet.Engine
  alias Licet.Engine.Membership
  alias Licet.Relationship

  @subject_part ~r/\[(.*)\]/
  @resource_part ~r/<([^>]+)>/
  @subject ~r/^(?<subject>[^\]\s]+)(?<caveat>\[\.\.\.\])?(\s+-\s+\{(?<exceptions>[^}]+)\})?$/

  @type onr :: {String.t(), String.t(), String.t()}
  @type entry :: %{
          text: String.t(),
          subject: onr() | nil,
          caveated: boolean(),
          exceptions: [String.t()],
          resources: [onr()]
        }
  @type t :: [{onr(), [entry()]}]

  @spec parse(%{String.t() => [String.t()]}) :: {:ok, t()} | {:error, String.t()}
  def parse(validation) do
    validation
    |> Enum.sort()
    |> collect(fn {key, lines} ->
      with {:ok, resource} <- key_object(key),
           {:ok, entries} <- collect(lines, &parse_line/1) do
        {:ok, {resource, entries}}
      end
    end)
  end

  @spec failures(map(), term(), map(), t()) :: [map()]
  def failures(schema, reader, revision, expected) do
    Enum.flat_map(expected, fn {resource, entries} ->
      case found(schema, reader, revision, resource) do
        {:ok, found} -> key_failures(onr(resource), entries, found)
        {:error, error} -> [%{relation: onr(resource), message: error.message}]
      end
    end)
  end

  @spec generate(map(), term(), map(), t()) ::
          {:ok, [{String.t(), [String.t()]}]} | {:error, Licet.Error.t()}
  def generate(schema, reader, revision, expected) do
    collect(expected, fn {resource, _entries} ->
      with {:ok, found} <- found(schema, reader, revision, resource) do
        {:ok, {onr(resource), found |> Enum.map(&line/1) |> Enum.sort()}}
      end
    end)
  end

  @spec format([{String.t(), [String.t()]}]) :: String.t()
  def format(generated) do
    Enum.map_join(generated, fn
      {key, []} ->
        key <> ": []\n"

      {key, lines} ->
        key <> ":\n" <> Enum.map_join(lines, &("    - '" <> &1 <> "'\n"))
    end)
  end

  defp line(found) do
    "[" <> validation_string(found) <> "] is " <> wrap(Enum.map(found.resources, &onr/1), "/")
  end

  defp found(schema, reader, revision, {type, id, relation}) do
    with {:ok, membership} <- Engine.membership(schema, reader, revision, type, id, relation) do
      {:ok, Membership.to_list(membership)}
    end
  end

  defp key_failures(name, entries, found) do
    by_subject = Map.new(found, &{onr(&1.subject), &1})
    failures = Enum.flat_map(entries, &entry_failures(name, &1, by_subject))

    listed =
      for %{subject: subject} when subject != nil <- entries, into: MapSet.new(), do: onr(subject)

    unlisted =
      for %{subject: subject} <- found, not MapSet.member?(listed, onr(subject)) do
        fail(name, "subject `#{onr(subject)}` found but not listed in expected subjects")
      end

    failures ++ unlisted
  end

  defp entry_failures(name, %{subject: nil, text: text}, _by_subject) do
    [fail(name, "no expected subject specified in `#{text}`")]
  end

  defp entry_failures(name, entry, by_subject) do
    case Map.fetch(by_subject, onr(entry.subject)) do
      {:ok, found} ->
        Enum.reject(
          [
            resources_failure(name, entry, found),
            exclusions_failure(name, entry, found),
            caveat_failure(name, entry)
          ],
          &is_nil/1
        )

      :error ->
        [fail(name, "missing expected subject `#{onr(entry.subject)}`")]
    end
  end

  defp resources_failure(name, entry, found) do
    specified = entry.resources |> Enum.map(&onr/1) |> Enum.sort()
    computed = Enum.map(found.resources, &onr/1)

    if specified != computed do
      fail(
        name,
        "found different relationships for subject `#{onr(found.subject)}`: " <>
          "Specified: `#{wrap(specified, "/")}`, Computed: `#{wrap(computed, "/")}`"
      )
    end
  end

  defp exclusions_failure(name, entry, %{subject: {_type, "*", _relation}} = found) do
    specified = Enum.sort(entry.exceptions)
    computed = Enum.map(found.excluded, &onr/1)

    if specified != computed do
      fail(
        name,
        "found different excluded subjects for subject `#{onr(found.subject)}`: " <>
          "Specified: `#{wrap(specified, ", ")}`, Computed: `#{wrap(computed, ", ")}`"
      )
    end
  end

  defp exclusions_failure(_name, %{exceptions: []}, _found), do: nil

  defp exclusions_failure(name, _entry, _found),
    do: fail(name, "found unexpected excluded subjects")

  defp caveat_failure(name, %{caveated: true}), do: fail(name, "found caveat mismatch")
  defp caveat_failure(_name, _entry), do: nil

  defp key_object(key) do
    case Relationship.parse_object(key) do
      {:ok, type, id, relation} when relation != "" -> {:ok, {type, id, relation}}
      _other -> {:error, "invalid resource and relation: `#{key}`: invalid ONR: #{key}"}
    end
  end

  defp parse_line(text) when is_binary(text) do
    with {:ok, resources} <- collect(resource_texts(text), &resource_object/1) do
      case Regex.run(@subject_part, text) do
        nil -> {:ok, entry(text, nil, resources)}
        [_all, subject] -> parse_subject(text, String.trim(subject), resources)
      end
    end
  end

  defp parse_line(other),
    do: {:error, "expected relation must be a string, got #{inspect(other)}"}

  defp resource_texts(text),
    do: @resource_part |> Regex.scan(text) |> Enum.map(fn [_, value] -> value end)

  defp resource_object(text) do
    case Relationship.parse_object(text) do
      {:ok, type, id, relation} when relation != "" -> {:ok, {type, id, relation}}
      _other -> {:error, "invalid resource and relation: `#{text}`: invalid ONR: #{text}"}
    end
  end

  defp parse_subject(text, subject, resources) do
    with %{"subject" => onr_text} = parts <- Regex.named_captures(@subject, subject),
         {:ok, subject_onr} <- subject_object(onr_text),
         {:ok, exceptions} <- exceptions(parts["exceptions"]) do
      {:ok,
       %{
         entry(text, subject_onr, resources)
         | caveated: parts["caveat"] != "",
           exceptions: exceptions
       }}
    else
      nil -> {:error, "invalid subject: `#{subject}`"}
      {:error, message} -> {:error, message}
    end
  end

  defp entry(text, subject, resources) do
    %{text: text, subject: subject, caveated: false, exceptions: [], resources: resources}
  end

  defp exceptions(text) do
    text
    |> String.split(",", trim: true)
    |> collect(fn exception ->
      {bare, marker} = split_caveat(String.trim(exception))

      with {:ok, parsed} <- subject_object(bare) do
        {:ok, onr(parsed) <> marker}
      end
    end)
  end

  defp split_caveat(exception) do
    case String.split(exception, "[...]") do
      [bare, ""] -> {bare, "[...]"}
      _other -> {exception, ""}
    end
  end

  defp subject_object(text) do
    case String.split(text, ":", parts: 2) do
      [_type, _id] -> object(text)
      _other -> {:error, "invalid subject: `#{text}`: invalid subject ONR: #{text}"}
    end
  end

  defp object(text) do
    case Relationship.parse_object(text) do
      {:ok, type, id, relation} -> {:ok, {type, id, relation}}
      {:error, _error} -> {:error, "invalid subject: `#{text}`: invalid subject ONR: #{text}"}
    end
  end

  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> then(fn
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end)
  end

  defp validation_string(%{subject: subject, excluded: []}), do: onr(subject)

  defp validation_string(%{subject: subject, excluded: excluded}) do
    onr(subject) <> " - {" <> Enum.map_join(excluded, ", ", &onr/1) <> "}"
  end

  defp wrap(strings, separator),
    do: strings |> Enum.sort() |> Enum.map_join(separator, &("<" <> &1 <> ">"))

  defp onr({type, id, ""}), do: type <> ":" <> id
  defp onr({type, id, relation}), do: type <> ":" <> id <> "#" <> relation

  defp fail(name, message) do
    %{relation: name, message: "For object and permission/relation `#{name}`, " <> message}
  end
end
