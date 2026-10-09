defmodule Licet.SpiceDBLiveCorpusTest do
  @moduledoc """
  Loads every runnable corpus file into a live SpiceDB and into Licet, then asks
  both the same questions: every check over the file's definitions, object ids,
  and subjects, every LookupResources, and every LookupSubjects for each
  subject type the file writes. Any difference fails, whether or not the
  corpus has an assertion for it.

  Excluded by default. Run with a SpiceDB on `LICET_SPICEDB_URL`:

      LICET_SPICEDB=1 mix test --only spicedb --include spicedb
  """

  use ExUnit.Case, async: false

  alias Licet.Conformance
  alias Licet.Engine
  alias Licet.Engine.Subjects
  alias Licet.SpiceDB

  @moduletag :spicedb
  @moduletag timeout: 600_000

  @opts [timeout: 30_000, parallel: nil]

  setup_all do
    Application.ensure_all_started(:req)
    :ok
  end

  for file <- Conformance.runnable() do
    test "#{file} agrees with a live SpiceDB" do
      source = File.read!(Path.join(Conformance.dir(), unquote(file)))
      {:ok, parsed} = Licet.Validate.parse(source)
      {:ok, %{"schema" => schema}} = YamlElixir.read_from_string(source)
      url = SpiceDB.url()

      assert :ok = SpiceDB.load(url, schema, parsed.relationships)

      data = Conformance.data(parsed)
      assert checks(url, data) ++ lookup_resources(url, data) ++ lookup_subjects(url, data) == []
    end
  end

  defp checks(url, data) do
    requests =
      for {type, name} <- data.names,
          id <- data.ids,
          subject <- data.subjects,
          do: {{type, id}, name, subject}

    {:ok, answers} = SpiceDB.check_bulk(url, requests)

    for {{{type, id}, name, subject} = request, spicedb} <- Enum.zip(requests, answers),
        licet = licet_check(data, request),
        licet != spicedb,
        do:
          "check #{type}:#{id}##{name}@#{onr(subject)}: SpiceDB #{inspect(spicedb)}, Licet #{inspect(licet)}"
  end

  defp licet_check(data, {{type, id}, name, subject}) do
    case Engine.check(
           data.schema,
           data.reader,
           data.revision,
           object({type, id, ""}),
           name,
           object(subject),
           @opts
         ) do
      {:ok, answer} -> {:ok, answer == :allowed}
      {:error, error} -> {:error, error.message}
    end
  end

  defp lookup_resources(url, data) do
    for {type, name} <- data.names,
        subject <- data.subjects,
        message <- lr_difference(url, data, type, name, subject),
        do: message
  end

  defp lr_difference(url, data, type, name, subject) do
    spicedb = SpiceDB.lookup_resources(url, type, name, subject)

    licet =
      Engine.resource_ids(
        data.schema,
        data.reader,
        data.revision,
        type,
        name,
        object(subject),
        @opts
      )

    case {spicedb, licet} do
      {same, same} ->
        []

      _ ->
        [
          "lookup_resources #{type}##{name} for #{onr(subject)}: SpiceDB #{lr(spicedb)}, Licet #{lr(licet)}"
        ]
    end
  end

  defp lookup_subjects(url, data) do
    for {type, id} <- data.resources,
        {^type, name} <- data.names,
        {subject_type, subject_relation} <- data.subject_types,
        message <- ls_difference(url, data, {type, id, name}, subject_type, subject_relation),
        do: message
  end

  defp ls_difference(url, data, {type, id, name}, subject_type, subject_relation) do
    spicedb = SpiceDB.lookup_subjects(url, {type, id}, name, subject_type, subject_relation)

    licet =
      with {:ok, set} <-
             Engine.subject_set(
               data.schema,
               data.reader,
               data.revision,
               type,
               id,
               name,
               {subject_type, subject_relation},
               @opts
             ) do
        {:ok,
         Map.new(Subjects.to_list(set), fn %{subject: {_type, sid, _rel}, excluded: excluded} ->
           {sid, excluded}
         end)}
      end

    case {spicedb, licet} do
      {same, same} ->
        []

      _ ->
        key =
          if subject_relation == "",
            do: subject_type,
            else: subject_type <> "#" <> subject_relation

        [
          "lookup_subjects #{type}:#{id}##{name} #{key}: SpiceDB #{ls(spicedb)}, Licet #{ls(licet)}"
        ]
    end
  end

  defp lr({:ok, ids}), do: inspect(Enum.sort(ids))
  defp lr({:error, error}), do: "error " <> inspect(error)

  defp ls({:ok, subjects}) do
    rendered =
      subjects
      |> Enum.sort()
      |> Enum.map_join(", ", fn
        {id, []} -> id
        {id, excluded} -> id <> " - {" <> Enum.join(excluded, ", ") <> "}"
      end)

    "[" <> rendered <> "]"
  end

  defp ls({:error, error}), do: "error " <> inspect(error)

  defp object({type, id, relation}), do: %{type: type, id: id, relation: relation}

  defp onr({type, id, ""}), do: type <> ":" <> id
  defp onr({type, id, relation}), do: type <> ":" <> id <> "#" <> relation
end
