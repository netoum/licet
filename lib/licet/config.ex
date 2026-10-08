defmodule Licet.Config do
  @moduledoc """
  Validates the options for a Licet instance.
  """

  @prefix ~r/^[a-z_][a-z0-9_]{0,62}$/

  @schema NimbleOptions.new!(
            name: [type: :atom, required: true],
            repo: [type: :atom, required: true],
            prefix: [type: :string, default: "licet"],
            schema: [type: {:or, [nil, {:tuple, [:atom, :any]}]}, default: nil],
            gc_interval: [type: {:or, [:non_neg_integer, {:in, [false]}]}, default: 300_000],
            gc_window: [type: :pos_integer, default: 86_400],
            quantization: [type: :pos_integer, default: 5_000],
            max_depth: [type: :pos_integer, default: 50],
            max_updates: [type: :pos_integer, default: 1_000],
            max_import: [type: :pos_integer, default: 10_000],
            max_preconditions: [type: :pos_integer, default: 1_000],
            timeout: [type: :pos_integer, default: 5_000],
            max_lookup: [type: :pos_integer, default: 10_000],
            gc_batch: [type: :pos_integer, default: 1_000]
          )

  @type t :: %{
          name: atom(),
          repo: module(),
          prefix: String.t(),
          schema: nil | {:file, Path.t()} | {:string, String.t()},
          gc_interval: non_neg_integer() | false,
          gc_window: pos_integer(),
          quantization: pos_integer(),
          max_depth: pos_integer(),
          max_updates: pos_integer(),
          max_import: pos_integer(),
          max_preconditions: pos_integer(),
          timeout: pos_integer(),
          max_lookup: pos_integer(),
          gc_batch: pos_integer()
        }

  @doc """
  Validates instance options and returns a config map.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    opts
    |> NimbleOptions.validate!(@schema)
    |> Map.new()
    |> normalize_schema()
    |> validate_prefix()
  end

  @doc false
  @spec fetch!(atom()) :: t()
  def fetch!(name) when is_atom(name) do
    case :persistent_term.get({Licet, name, :config}, :missing) do
      :missing -> raise Licet.Error.new(:not_started, "#{inspect(name)} is not running")
      config -> config
    end
  end

  defp normalize_schema(%{schema: nil} = config), do: config
  defp normalize_schema(%{schema: {:file, path}} = config) when is_binary(path), do: config
  defp normalize_schema(%{schema: {:string, source}} = config) when is_binary(source), do: config

  defp normalize_schema(%{schema: other}) do
    raise Licet.Error.new(
            :invalid_config,
            "schema must be nil, {:file, path}, or {:string, source}, got #{inspect(other)}"
          )
  end

  defp validate_prefix(%{prefix: prefix} = config) do
    if Regex.match?(@prefix, prefix) do
      config
    else
      raise Licet.Error.new(
              :invalid_config,
              "prefix #{inspect(prefix)} is not a safe Postgres identifier"
            )
    end
  end
end
