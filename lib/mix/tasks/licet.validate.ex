defmodule Mix.Tasks.Licet.Validate do
  @moduledoc """
  Checks a SpiceDB validation file against Licet.

      mix licet.validate test/conformance/document.yaml
  """

  use Mix.Task

  @shortdoc "Validates a .zed schema and assertions"

  @impl Mix.Task
  def run([path]) do
    case Licet.Validate.run_file(path) do
      :ok ->
        Mix.shell().info("licet validation passed")

      {:error, failures} when is_list(failures) ->
        Mix.raise(format(failures))

      {:error, %Licet.Error{} = error} ->
        Mix.raise(error.message)
    end
  end

  def run(_args) do
    Mix.raise("usage: mix licet.validate FILE")
  end

  defp format(failures) do
    Enum.map_join(failures, "\n", fn failure ->
      "#{failure.assertion} expected #{failure.expected}, got #{inspect(failure.got)}"
    end)
  end
end
