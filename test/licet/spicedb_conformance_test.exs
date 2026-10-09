defmodule Licet.SpiceDBConformanceTest do
  @moduledoc """
  Runs SpiceDB's own consistency corpus, vendored from
  `internal/services/integrationtesting/testconfigs` under its Apache-2.0
  license, on the in-memory reader.
  """

  use ExUnit.Case, async: true

  alias Licet.Conformance

  test "every vendored file is run or skipped with a reason" do
    assert MapSet.subset?(
             MapSet.new(Map.keys(Conformance.skipped())),
             MapSet.new(Conformance.files())
           )
  end

  for {file, reason} <- Conformance.skipped() do
    test "#{file} is skipped: #{reason}" do
      assert {:error, %Licet.Error{reason: :invalid_schema, message: unquote(reason)}} =
               Licet.Validate.run_file(Path.join(Conformance.dir(), unquote(file)))
    end
  end

  for file <- Conformance.runnable() do
    describe file do
      test "assertions and expected relations hold" do
        assert Licet.Validate.run_file(Path.join(Conformance.dir(), unquote(file))) == :ok
      end

      test "check, lookups, and expand agree" do
        {:ok, parsed} =
          Licet.Validate.parse(File.read!(Path.join(Conformance.dir(), unquote(file))))

        assert Conformance.run(parsed) == []
      end
    end
  end
end
