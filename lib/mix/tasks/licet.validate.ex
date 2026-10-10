defmodule Mix.Tasks.Licet.Validate do
  @moduledoc """
  Runs a SpiceDB validation file: its assertions and expected relations.

      $ mix licet.validate test/permissions/documents.yaml
      licet validation passed

  The task exits with an error and lists every failure when the file doesn't
  pass, so it can run in CI. A schema error is reported as
  `FILE:LINE:COLUMN: message`, with the position inside the `schema` block.
  It needs no database. See `Licet.Validate` for the file format and
  [Testing](testing.md) for an example.

  Run `mix licet.validate --help` to print this help.
  """

  use Mix.Task

  @shortdoc "Runs a SpiceDB validation file"

  @impl Mix.Task
  def run([flag]) when flag in ["--help", "-h"] do
    Mix.Task.rerun("help", ["licet.validate"])
  end

  def run([path]) do
    case Licet.Validate.run_file(path) do
      :ok ->
        Mix.shell().info("licet validation passed")

      {:error, failures} when is_list(failures) ->
        Mix.raise(format(failures))

      {:error, %Licet.Error{} = error} ->
        Mix.raise(location(path, error.details) <> error.message)
    end
  end

  def run(_args) do
    Mix.raise("usage: mix licet.validate FILE")
  end

  defp location(path, %{line: line, column: column}), do: "#{path}:#{line}:#{column}: "
  defp location(path, _details), do: "#{path}: "

  defp format(failures), do: Enum.map_join(failures, "\n", &format_failure/1)

  defp format_failure(%{assertion: assertion, expected: expected, got: got}) do
    "#{assertion} expected #{expected}, got #{inspect(got)}"
  end

  defp format_failure(%{message: message}), do: message
end
