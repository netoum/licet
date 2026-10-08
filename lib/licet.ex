defmodule Licet do
  @moduledoc """
  Relationship-based authorization stored in your Postgres database.

  Start one instance beside your repo:

      children = [
        MyApp.Repo,
        {Licet,
         name: MyApp.Licet,
         repo: MyApp.Repo,
         prefix: "licet",
         schema: {:file, "priv/licet/schema.zed"}}
      ]

  Writes participate in the caller's `Repo.transaction/2`. A check inside that
  transaction sees its own uncommitted writes and does not use the shared cache.
  """

  use Supervisor

  alias Licet.Config
  alias Licet.Dispatch
  alias Licet.Engine
  alias Licet.Error
  alias Licet.Reader.Postgres
  alias Licet.Relationship
  alias Licet.Revision
  alias Licet.SchemaServer
  alias Licet.Store

  @doc """
  Starts a Licet instance.
  """
  @spec start_link(keyword() | map()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts), do: start_link(Config.new!(opts))

  def start_link(%{} = config) do
    Supervisor.start_link(__MODULE__, config, name: config.name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    config = Config.new!(opts)

    %{
      id: config.name,
      start: {__MODULE__, :start_link, [config]},
      type: :supervisor
    }
  end

  @impl true
  def init(config) do
    :persistent_term.put({Licet, config.name, :config}, config)

    children = [
      {Licet.Cache, config},
      {Registry, keys: :unique, name: Module.concat(config.name, Registry)},
      {Task.Supervisor, name: Module.concat(config.name, Tasks)},
      {SchemaServer, config},
      {Revision, config},
      {Licet.GC, config}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Writes relationship updates.

  Each update is `{:create, tuple}`, `{:touch, tuple}`, or `{:delete, tuple}`.
  A tuple is a `Licet.Relationship` or text such as `document:1#viewer@user:anne`.
  """
  @spec write(atom(), list(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def write(name, updates, opts \\ []) when is_list(updates) do
    with {:ok, config} <- fetch(name) do
      do_write(config, name, updates, opts, config.max_updates)
    end
  end

  @doc """
  Tombstones relationships that match `filter`. `resource_type` is required.
  """
  @spec delete(atom(), map(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def delete(name, filter, opts \\ []) when is_map(filter) do
    with {:ok, config} <- fetch(name) do
      metadata = Keyword.get(opts, :metadata, %{})

      transact(config.repo, fn ->
        Store.delete_matching(config.repo, config.prefix, filter, metadata)
      end)
    end
  end

  @doc """
  Reads relationships visible at the requested consistency.
  """
  @spec read(atom(), map(), keyword()) :: {:ok, [Relationship.t()]} | {:error, Error.t()}
  def read(name, filter, opts \\ []) when is_map(filter) do
    with {:ok, config} <- fetch(name),
         {:ok, revision} <-
           Revision.resolve(config, Keyword.get(opts, :consistency, :minimize_latency)) do
      Store.read(config.repo, config.prefix, revision, filter)
    end
  end

  @doc """
  Returns `:allowed` when `subject` has `permission` on `resource`.
  """
  @spec check(atom(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, :allowed | :denied} | {:error, Error.t()}
  def check(name, resource, permission, subject, opts \\ []) do
    meta = %{resource: resource, permission: permission, subject: subject}

    :telemetry.span([:licet, :check], meta, fn ->
      {do_check(name, resource, permission, subject, opts), meta}
    end)
  end

  @doc """
  Checks many permissions. Order is preserved. One failure does not stop the rest.
  """
  @spec check_bulk(atom(), [map()], keyword()) :: {:ok, [result]} | {:error, Error.t()}
        when result: {:ok, :allowed | :denied} | {:error, Error.t()}
  def check_bulk(name, checks, opts \\ []) when is_list(checks) do
    with {:ok, prepared} <- prepare(name, opts) do
      {:ok, Enum.map(checks, &bulk_one(prepared, &1, opts))}
    end
  end

  @doc """
  Lists resource ids of `type` on which `subject` has `permission`.
  """
  @spec lookup_resources(atom(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [String.t()], String.t() | nil} | {:error, Error.t()}
  def lookup_resources(name, type, permission, subject, opts \\ []) do
    meta = %{resource_type: type, permission: permission, subject: subject}

    :telemetry.span([:licet, :lookup], meta, fn ->
      {do_lookup_resources(name, type, permission, subject, opts), meta}
    end)
  end

  @doc """
  Lists subjects that have `permission` on `resource`.
  """
  @spec lookup_subjects(atom(), String.t(), String.t(), keyword()) ::
          {:ok, [String.t()], String.t() | nil} | {:error, Error.t()}
  def lookup_subjects(name, resource, permission, opts \\ []) do
    meta = %{resource: resource, permission: permission}

    :telemetry.span([:licet, :lookup], meta, fn ->
      {do_lookup_subjects(name, resource, permission, opts), meta}
    end)
  end

  @doc """
  Explains a check.
  """
  @spec explain(atom(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, :allowed | :denied, map()} | {:error, Error.t()}
  def explain(name, resource, permission, subject, opts \\ []) do
    with {:ok, prepared} <- prepare(name, opts),
         {:ok, resource} <- object(resource, false),
         {:ok, subject} <- object(subject, true) do
      Engine.explain(
        prepared.schema,
        prepared.reader,
        prepared.revision,
        resource,
        permission,
        subject,
        prepared.opts
      )
    end
  end

  @doc """
  Stores a new schema after rejecting unsafe changes.
  """
  @spec write_schema(atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def write_schema(name, source, opts \\ []) when is_binary(source) do
    with {:ok, config} <- fetch(name),
         {:ok, parsed} <- Licet.Schema.parse(source),
         {:ok, old} <- current_parsed(config) do
      metadata = Keyword.get(opts, :metadata, %{})

      result =
        transact(config.repo, fn ->
          with :ok <- Store.ensure_compatible(config.repo, config.prefix, old, parsed) do
            Store.write_schema(config.repo, config.prefix, source, parsed.hash, metadata)
          end
        end)

      case result do
        {:ok, token} ->
          SchemaServer.put(name, parsed)
          {:ok, token}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Creates relationships in one transaction. Existing tuples fail the import.
  """
  @spec import(atom(), [String.t() | Relationship.t()], keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def import(name, relationships, opts \\ []) when is_list(relationships) do
    with {:ok, config} <- fetch(name),
         :ok <- within(relationships, config.max_import) do
      do_write(config, name, Enum.map(relationships, &{:create, &1}), opts, config.max_import)
    end
  end

  defp do_write(config, name, updates, opts, limit) do
    with :ok <- within(updates, limit),
         {:ok, schema} <- SchemaServer.get(name),
         {:ok, normalized} <- normalize_updates(updates),
         {:ok, preconditions} <- normalize_preconditions(opts) do
      metadata = Keyword.get(opts, :metadata, %{})

      :telemetry.span([:licet, :write], %{count: length(updates)}, fn ->
        result =
          transact(config.repo, fn ->
            Store.write(config.repo, config.prefix, normalized, preconditions, metadata, schema)
          end)

        {result, %{count: length(updates)}}
      end)
    end
  end

  defp do_check(name, resource, permission, subject, opts) do
    with {:ok, prepared} <- prepare(name, opts),
         {:ok, resource} <- object(resource, false),
         {:ok, subject} <- object(subject, true) do
      run_check(prepared, resource, permission, subject)
    end
  end

  defp do_lookup_resources(name, type, permission, subject, opts) do
    with {:ok, prepared} <- prepare(name, opts),
         {:ok, subject} <- object(subject, true),
         {:ok, ids} <-
           Engine.resource_ids(
             prepared.schema,
             prepared.reader,
             prepared.revision,
             type,
             permission,
             subject,
             prepared.opts
           ) do
      Licet.Page.slice(
        Enum.to_list(ids),
        Keyword.get(opts, :cursor),
        Keyword.get(opts, :limit, 100)
      )
    end
  end

  defp do_lookup_subjects(name, resource, permission, opts) do
    with {:ok, prepared} <- prepare(name, opts),
         {:ok, resource} <- object(resource, false),
         {:ok, set} <-
           Engine.subject_set(
             prepared.schema,
             prepared.reader,
             prepared.revision,
             resource.type,
             resource.id,
             permission,
             prepared.opts
           ) do
      rendered = Enum.map(Licet.Engine.Subjects.to_list(set), &format_subject/1)
      Licet.Page.slice(rendered, Keyword.get(opts, :cursor), Keyword.get(opts, :limit, 100))
    end
  end

  defp prepare(name, opts) do
    with {:ok, config} <- fetch(name),
         {:ok, schema} <- SchemaServer.get(name),
         {:ok, revision} <-
           Revision.resolve(config, Keyword.get(opts, :consistency, :minimize_latency)) do
      {:ok,
       %{
         config: config,
         schema: schema,
         revision: revision,
         reader: %Postgres{repo: config.repo, prefix: config.prefix},
         opts: engine_opts(config)
       }}
    end
  end

  defp engine_opts(config) do
    [
      timeout: config.timeout,
      max_depth: config.max_depth,
      max_lookup: config.max_lookup,
      parallel: %{supervisor: Module.concat(config.name, Tasks), repo: config.repo}
    ]
  end

  defp run_check(%{revision: %{cache?: false}} = prepared, resource, permission, subject) do
    Engine.check(
      prepared.schema,
      prepared.reader,
      prepared.revision,
      resource,
      permission,
      subject,
      prepared.opts
    )
  end

  defp run_check(prepared, resource, permission, subject) do
    key = {prepared.revision.snapshot, resource, permission, subject}

    Dispatch.compute(prepared.config.name, key, prepared.config.timeout, fn ->
      Engine.check(
        prepared.schema,
        prepared.reader,
        prepared.revision,
        resource,
        permission,
        subject,
        prepared.opts
      )
    end)
  end

  defp bulk_one(prepared, check, _opts) do
    with {:ok, resource} <- object(check.resource, false),
         {:ok, subject} <- object(check.subject, true) do
      run_check(prepared, resource, check.permission, subject)
    end
  end

  defp object(value, allow_wildcard) do
    case Relationship.parse_object(value) do
      {:ok, _type, "*", _relation} when not allow_wildcard ->
        {:error, Error.new(:invalid_relationship, "resource cannot be a wildcard")}

      {:ok, type, id, relation} ->
        {:ok, %{type: type, id: id, relation: relation}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp format_subject({type, id, ""}), do: type <> ":" <> id
  defp format_subject({type, id, relation}), do: type <> ":" <> id <> "#" <> relation

  defp normalize_updates(updates) do
    Enum.reduce_while(updates, {:ok, []}, fn update, {:ok, acc} ->
      case normalize_update(update) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_update({action, %Relationship{} = rel})
       when action in [:create, :touch, :delete] do
    {:ok, {action, rel}}
  end

  defp normalize_update({action, text})
       when action in [:create, :touch, :delete] and is_binary(text) do
    case Relationship.parse(text) do
      {:ok, rel} -> {:ok, {action, rel}}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_update(other) do
    {:error, Error.new(:invalid_relationship, "invalid update #{inspect(other)}")}
  end

  defp normalize_preconditions(opts) do
    preconditions = Keyword.get(opts, :preconditions, [])

    if is_list(preconditions) do
      {:ok, preconditions}
    else
      {:error, Error.new(:invalid_filter, "preconditions must be a list")}
    end
  end

  defp current_parsed(config) do
    case Store.current_schema(config.repo, config.prefix) do
      {:ok, nil} -> {:ok, nil}
      {:ok, source} -> Licet.Schema.parse(source)
      {:error, error} -> {:error, error}
    end
  end

  defp within(list, max) do
    if length(list) > max do
      {:error, Error.new(:too_many_updates, "expected at most #{max} updates")}
    else
      :ok
    end
  end

  defp fetch(name) do
    case :persistent_term.get({Licet, name, :config}, :missing) do
      :missing -> {:error, Error.new(:not_started, "#{inspect(name)} is not running")}
      config -> {:ok, config}
    end
  end

  defp transact(repo, fun) do
    runner = fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, error} -> repo.rollback(error)
      end
    end

    if in_transaction?(repo) do
      {:ok, runner.()}
    else
      case repo.transaction(runner) do
        {:ok, value} -> {:ok, value}
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  defp in_transaction?(repo) do
    repo
    |> Ecto.Adapter.lookup_meta()
    |> Ecto.Adapters.SQL.in_transaction?()
  end
end
