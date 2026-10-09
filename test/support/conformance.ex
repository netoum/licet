defmodule Licet.Conformance do
  @moduledoc """
  SpiceDB's consistency suite (`internal/services/integrationtesting/consistencytestutil`)
  over one validation file, on the in-memory reader.

  Like SpiceDB it first checks every definition, object id, relation, and
  defined subject, then requires the other APIs to agree with those answers:

  * `lookup_resources` returns exactly the accessible resources
  * `lookup_subjects` contains every accessible defined subject and only subjects that check
  * every subject a recursive expand reaches checks as allowed
  * every assertion agrees with `lookup_resources`

  Returns a list of failure messages; an empty list is a pass.
  """

  alias Licet.Engine
  alias Licet.Engine.Membership
  alias Licet.Engine.Subjects
  alias Licet.Reader.Memory
  alias Licet.Relationship

  @opts [timeout: 30_000]

  @dir "test/conformance/spicedb"
  @caveats "caveats are not supported"

  @skipped %{
    "allopscaveat.yaml" => @caveats,
    "basiccaveat.yaml" => @caveats,
    "caveatarrow.yaml" => @caveats,
    "caveatedintersectionarrow.yaml" => @caveats,
    "caveatexpiration.yaml" => @caveats,
    "caveatindirectarrow.yaml" => @caveats,
    "caveatip.yaml" => @caveats,
    "caveatlist.yaml" => @caveats,
    "caveatlr.yaml" => @caveats,
    "caveatmap.yaml" => @caveats,
    "caveatmultiplebranchessamerel.yaml" => @caveats,
    "caveatunderarrow.yaml" => @caveats,
    "caveatunderintersect.yaml" => @caveats,
    "expirationwithcaveat.yaml" => @caveats,
    "multibranchcaveatwitharrows.yaml" => @caveats,
    "multibranchcaveatwithintersectionarrows.yaml" => @caveats,
    "multipleslashes.yaml" => @caveats,
    "publiccaveat.yaml" => @caveats,
    "publiccaveatexclusion.yaml" => @caveats,
    "quay.yaml" => @caveats,
    "self.yaml.skip" => "self is not supported"
  }

  @doc "The directory holding the vendored corpus."
  @spec dir() :: Path.t()
  def dir, do: @dir

  @doc "Corpus files Licet cannot run, with the schema error each one must produce."
  @spec skipped() :: %{String.t() => String.t()}
  def skipped, do: @skipped

  @doc "Every vendored corpus file, sorted."
  @spec files() :: [String.t()]
  def files, do: @dir |> File.ls!() |> Enum.reject(&(&1 == "LICENSE")) |> Enum.sort()

  @doc "The corpus files Licet runs."
  @spec runnable() :: [String.t()]
  def runnable, do: Enum.reject(files(), &Map.has_key?(@skipped, &1))

  @spec run(Licet.Validate.t()) :: [String.t()]
  def run(%Licet.Validate{} = file) do
    data = data(file)

    case accessibility(data) do
      {:ok, access} ->
        data = Map.put(data, :access, access)
        lookup_resources(data) ++ lookup_subjects(data) ++ expansion(data) ++ assertions(data)

      {:error, message} ->
        [message]
    end
  end

  @doc """
  The query space of a validation file, as SpiceDB's consistency suite builds
  it: every definition name, object id, defined subject, resource, and the
  `{type, relation}` subject types the relationships write.
  """
  @spec data(Licet.Validate.t()) :: map()
  def data(%Licet.Validate{} = file) do
    rels = file.relationships

    %{
      subject_types: rels |> Enum.map(&{&1.subject_type, &1.subject_relation}) |> Enum.uniq(),
      file: file,
      schema: file.schema,
      reader: %Memory{tuples: rels},
      revision: %{snapshot: "0:0:", own_xid: "", at: DateTime.utc_now()},
      names: names(file.schema),
      ids: rels |> Enum.flat_map(&[&1.resource_id, &1.subject_id]) |> Enum.reject(&(&1 == "*")),
      subjects: rels |> Enum.map(&subject/1) |> Enum.reject(&(elem(&1, 1) == "*")) |> Enum.uniq(),
      resources: rels |> Enum.map(&{&1.resource_type, &1.resource_id}) |> Enum.uniq()
    }
    |> Map.update!(:ids, &Enum.uniq/1)
  end

  defp names(schema) do
    for {type, definition} <- schema.definitions,
        name <- Map.keys(definition.relations) ++ Map.keys(definition.permissions),
        do: {type, name}
  end

  defp subject(rel), do: {rel.subject_type, rel.subject_id, rel.subject_relation}

  defp accessibility(data) do
    pairs =
      for {type, name} <- data.names,
          id <- data.ids,
          subject <- data.subjects,
          do: {{type, id, name}, subject}

    Enum.reduce_while(pairs, {:ok, %{}}, fn {resource, subject} = pair, {:ok, acc} ->
      case check(data, resource, subject) do
        {:ok, answer} ->
          {:cont, {:ok, Map.put(acc, pair, answer)}}

        {:error, error} ->
          {:halt, {:error, "check #{rel(resource, subject)} failed: #{error.message}"}}
      end
    end)
  end

  defp lookup_resources(data) do
    for {type, name} <- data.names,
        subject <- data.subjects,
        message <- lr_failure(data, type, name, subject) do
      message
    end
  end

  defp lr_failure(data, type, name, subject) do
    expected =
      for {{{^type, id, ^name}, ^subject}, :allowed} <- data.access, into: MapSet.new(), do: id

    case Engine.resource_ids(
           data.schema,
           data.reader,
           data.revision,
           type,
           name,
           object(subject),
           @opts
         ) do
      {:ok, ^expected} ->
        []

      {:ok, found} ->
        [
          "lookup_resources #{type}##{name} for #{onr(subject)}: " <>
            "expected #{inspect(Enum.sort(expected))}, got #{inspect(Enum.sort(found))}"
        ]

      {:error, error} ->
        ["lookup_resources #{type}##{name} for #{onr(subject)} failed: #{error.message}"]
    end
  end

  defp lookup_subjects(data) do
    for {type, id} <- data.resources,
        {^type, name} <- data.names,
        message <- ls_failures(data, {type, id, name}) do
      message
    end
  end

  defp ls_failures(data, resource) do
    Enum.flat_map(data.subject_types, &ls_type_failures(data, resource, &1))
  end

  defp ls_type_failures(data, {type, id, name} = resource, subject_type) do
    case Engine.subject_set(
           data.schema,
           data.reader,
           data.revision,
           type,
           id,
           name,
           subject_type,
           @opts
         ) do
      {:ok, set} ->
        found = Subjects.to_list(set)

        missing_subjects(data, resource, subject_type, found) ++
          unchecked_subjects(data, resource, found)

      {:error, error} ->
        ["lookup_subjects #{onr(resource)} failed: #{error.message}"]
    end
  end

  defp missing_subjects(data, resource, {subject_type, subject_relation}, found) do
    for {{^resource, {^subject_type, _id, ^subject_relation} = subject}, :allowed} <- data.access,
        not covers?(found, subject),
        do: "lookup_subjects #{onr(resource)} is missing #{onr(subject)}"
  end

  defp unchecked_subjects(data, resource, found) do
    for %{subject: {_type, id, _relation} = subject} <- found,
        id != "*",
        check(data, resource, subject) != {:ok, :allowed},
        do: "lookup_subjects #{onr(resource)} returned #{onr(subject)}, which does not check"
  end

  defp covers?(found, {type, id, relation}) do
    Enum.any?(found, fn
      %{subject: {^type, "*", ^relation}, excluded: excluded} -> id not in excluded
      %{subject: subject} -> subject == {type, id, relation}
    end)
  end

  defp expansion(data) do
    for {type, id} <- data.resources,
        {^type, name} <- data.names,
        message <- expansion_failures(data, {type, id, name}) do
      message
    end
  end

  defp expansion_failures(data, {type, id, name} = resource) do
    case Engine.membership(data.schema, data.reader, data.revision, type, id, name, @opts) do
      {:ok, membership} ->
        for %{subject: {_type, subject_id, _relation} = subject} <- Membership.to_list(membership),
            subject_id != "*",
            check(data, resource, subject) != {:ok, :allowed},
            do: "expand #{onr(resource)} reached #{onr(subject)}, which does not check"

      {:error, error} ->
        ["expand #{onr(resource)} failed: #{error.message}"]
    end
  end

  defp assertions(data) do
    Enum.flat_map(data.file.assert_true, &assertion_failure(data, &1, true)) ++
      Enum.flat_map(data.file.assert_false, &assertion_failure(data, &1, false))
  end

  defp assertion_failure(data, line, expected) do
    {:ok, rel} = Relationship.parse(line)

    case Engine.resource_ids(
           data.schema,
           data.reader,
           data.revision,
           rel.resource_type,
           rel.relation,
           object(subject(rel)),
           @opts
         ) do
      {:ok, ids} ->
        if MapSet.member?(ids, rel.resource_id) == expected,
          do: [],
          else: ["lookup_resources disagrees with assertion #{line}"]

      {:error, error} ->
        ["lookup_resources for assertion #{line} failed: #{error.message}"]
    end
  end

  defp check(data, {type, id, name}, subject) do
    Engine.check(
      data.schema,
      data.reader,
      data.revision,
      %{type: type, id: id, relation: ""},
      name,
      object(subject),
      @opts
    )
  end

  defp object({type, id, relation}), do: %{type: type, id: id, relation: relation}

  defp rel(resource, subject), do: onr(resource) <> "@" <> onr(subject)

  defp onr({type, id, ""}), do: type <> ":" <> id
  defp onr({type, id, relation}), do: type <> ":" <> id <> "#" <> relation
end
