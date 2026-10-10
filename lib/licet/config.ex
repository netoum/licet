defmodule Licet.Config do
  # Validates the options for a Licet instance.
  @moduledoc false

  @prefix ~r/^[a-z_][a-z0-9_]{0,62}$/

  @schema NimbleOptions.new!(
            name: [
              type: :atom,
              required: true,
              doc: "The instance name, passed as the first argument of every `Licet` function."
            ],
            repo: [
              type: :atom,
              required: true,
              doc: "The `Ecto.Repo` that holds Licet's tables."
            ],
            prefix: [
              type: :string,
              default: "licet",
              doc:
                "The Postgres schema that holds the tables. It must match `^[a-z_][a-z0-9_]{0,62}$`."
            ],
            schema: [
              type: {:or, [nil, {:tuple, [:atom, :any]}]},
              default: nil,
              doc: """
              The schema to load at startup, as `{:file, path}` or `{:string, source}`. When it
              differs from the stored schema, it is stored as a new version, unless the change would
              strand stored relationships. `nil` keeps the stored schema.
              """
            ],
            quantization: [
              type: :pos_integer,
              default: 5_000,
              doc:
                "Milliseconds between refreshes of the snapshot that `:minimize_latency` reads."
            ],
            timeout: [
              type: :pos_integer,
              default: 5_000,
              doc: "Milliseconds allowed for one check or lookup."
            ],
            max_depth: [
              type: :pos_integer,
              default: 50,
              doc: "Arrow and userset hops allowed in one check."
            ],
            max_lookup: [
              type: :pos_integer,
              default: 10_000,
              doc: "Results one lookup may compute before failing with `:lookup_too_large`."
            ],
            max_updates: [
              type: :pos_integer,
              default: 1_000,
              doc: "Updates allowed in one `Licet.write/3`."
            ],
            max_import: [
              type: :pos_integer,
              default: 10_000,
              doc: "Relationships allowed in one `Licet.import/3`."
            ],
            max_preconditions: [
              type: :pos_integer,
              default: 1_000,
              doc: "Preconditions allowed on one write."
            ],
            gc_interval: [
              type: {:or, [:pos_integer, {:in, [false]}]},
              default: 300_000,
              doc: "Milliseconds between garbage collections, or `false` to disable them."
            ],
            gc_window: [
              type: :pos_integer,
              default: 86_400,
              doc: "Seconds of history to keep. Exact reads of older tokens fail."
            ],
            gc_batch: [
              type: :pos_integer,
              default: 1_000,
              doc: "Rows deleted per garbage collection batch."
            ]
          )

  @type t :: %{
          name: atom(),
          repo: module(),
          prefix: String.t(),
          schema: nil | {:file, Path.t()} | {:string, String.t()},
          gc_interval: pos_integer() | false,
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

  @doc false
  @spec docs() :: String.t()
  def docs, do: NimbleOptions.docs(@schema)

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
