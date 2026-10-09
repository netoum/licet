defmodule Licet.SpiceDBConformancePostgresTest do
  @moduledoc """
  Runs the vendored SpiceDB corpus a second time through Postgres: each file's
  schema and relationships go through the public API, and every assertion is
  checked at `consistency: :full` with `check/5`, `check_bulk/3`, and
  `lookup_resources/5`.
  """

  use Licet.DataCase, async: false

  alias Licet.Conformance
  alias Licet.Relationship

  @full [consistency: :full]
  @chunk 500

  for file <- Conformance.runnable() do
    test "#{file} holds through Postgres" do
      source = File.read!(Path.join(Conformance.dir(), unquote(file)))
      {:ok, parsed} = Licet.Validate.parse(source)
      {:ok, %{"schema" => schema}} = YamlElixir.read_from_string(source)
      name = start_licet!(schema)

      parsed.relationships
      |> Enum.map(&{:touch, &1})
      |> Enum.chunk_every(@chunk)
      |> Enum.each(&({:ok, _token} = Licet.write(name, &1)))

      checks =
        Enum.map(parsed.assert_true, &{&1, :allowed}) ++
          Enum.map(parsed.assert_false, &{&1, :denied})

      assert failures(name, checks) == []
    end
  end

  defp failures(name, checks) do
    requests = Enum.map(checks, fn {line, _expected} -> request(line) end)
    {:ok, bulk} = Licet.check_bulk(name, requests, @full)

    checks
    |> Enum.zip(Enum.zip(requests, bulk))
    |> Enum.flat_map(fn {{line, expected}, {request, bulk_result}} ->
      single = Licet.check(name, request.resource, request.permission, request.subject, @full)
      looked_up = looked_up(name, request)

      if single == {:ok, expected} and bulk_result == {:ok, expected} and
           looked_up == (expected == :allowed),
         do: [],
         else: [
           %{
             assertion: line,
             expected: expected,
             check: single,
             bulk: bulk_result,
             lookup: looked_up
           }
         ]
    end)
  end

  defp looked_up(name, request) do
    [type, id] = String.split(request.resource, ":", parts: 2)

    {:ok, ids, _cursor} =
      Licet.lookup_resources(name, type, request.permission, request.subject, @full)

    id in ids
  end

  defp request(line) do
    {:ok, rel} = Relationship.parse(line)
    subject = rel.subject_type <> ":" <> rel.subject_id

    %{
      resource: rel.resource_type <> ":" <> rel.resource_id,
      permission: rel.relation,
      subject:
        if(rel.subject_relation == "", do: subject, else: subject <> "#" <> rel.subject_relation)
    }
  end
end
