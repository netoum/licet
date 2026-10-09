defmodule Playground.Result do
  @moduledoc """
  What `Licet.Validate` says about one validation file.

  `watches` lists every assertion with its outcome, the way play.authzed.com
  shows Check Watches. `expected` holds the expected-relation failures, in
  SpiceDB's wording. `error` is set when the file itself is rejected, for
  example a schema that uses caveats.
  """

  defstruct error: nil, watches: [], expected: []

  @type watch :: %{
          assertion: String.t(),
          expected: :allowed | :denied,
          outcome: :pass | {:fail, term()}
        }

  @type t :: %__MODULE__{
          error: Licet.Error.t() | nil,
          watches: [watch()],
          expected: [String.t()]
        }

  @spec new(String.t()) :: t()
  def new(yaml) when is_binary(yaml) do
    with {:ok, file} <- Licet.Validate.parse(yaml),
         {:ok, failures} <- failures(yaml) do
      failed = for %{assertion: line, got: got} <- failures, into: %{}, do: {line, got}

      %__MODULE__{
        watches:
          Enum.map(file.assert_true, &watch(&1, :allowed, failed)) ++
            Enum.map(file.assert_false, &watch(&1, :denied, failed)),
        expected: for(%{message: message} <- failures, do: message)
      }
    else
      {:error, %Licet.Error{} = error} -> %__MODULE__{error: error}
    end
  end

  @spec passed?(t()) :: boolean()
  def passed?(%__MODULE__{error: nil, expected: [], watches: watches}),
    do: Enum.all?(watches, &(&1.outcome == :pass))

  def passed?(%__MODULE__{}), do: false

  @spec format_watches([watch()]) :: String.t()
  def format_watches(watches), do: Enum.map_join(watches, "\n", &format_watch/1)

  defp failures(yaml) do
    case Licet.Validate.run(yaml) do
      :ok -> {:ok, []}
      {:error, failures} when is_list(failures) -> {:ok, failures}
      {:error, %Licet.Error{} = error} -> {:error, error}
    end
  end

  defp watch(line, expected, failed) do
    outcome =
      case Map.fetch(failed, line) do
        {:ok, got} -> {:fail, got}
        :error -> :pass
      end

    %{assertion: line, expected: expected, outcome: outcome}
  end

  defp format_watch(%{assertion: line, outcome: :pass, expected: expected}),
    do: "✓ #{line}  #{expected}"

  defp format_watch(%{assertion: line, outcome: {:fail, got}, expected: expected}),
    do: "✗ #{line}  expected #{expected}, got #{got(got)}"

  defp got({:ok, answer}), do: Atom.to_string(answer)
  defp got({:error, %Licet.Error{message: message}}), do: message
  defp got(other), do: inspect(other)
end
