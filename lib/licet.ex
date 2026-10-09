defmodule Licet do
  @moduledoc """
  Relationship-based authorization, stored in your Postgres database.

  This module is the whole runtime API: start an instance, write relationships,
  and ask questions about them. [Getting started](getting-started.md) walks
  through a first setup, and [Concepts](concepts.md) explains the vocabulary.

  ## Starting an instance

  Add an instance to your supervision tree, after the repo it uses:

      children = [
        MyApp.Repo,
        {Licet,
         name: MyApp.Licet,
         repo: MyApp.Repo,
         schema: {:file, Application.app_dir(:my_app, "priv/licet/schema.zed")}}
      ]

  The tables must exist first. Create them with `mix licet.gen.migration`.

  ## Instance names

  Every function takes the instance `name` as its first argument. It is the
  atom given in the child spec, usually a module-like name such as
  `MyApp.Licet`. Choose it in code, never from user input. Calling a function
  on a name that isn't running returns `{:error, %Licet.Error{reason: :not_started}}`.

  ## Options

  #{Licet.Config.docs()}

  ## Objects and relationships

  Functions take objects and relationships as text, in SpiceDB's format:

    * an object is `type:id`, such as `"document:roadmap"`;
    * a userset subject is `type:id#relation`, such as `"team:eng#member"`;
    * a wildcard subject is `type:*`, such as `"user:*"`;
    * a relationship is `resource#relation@subject`, such as
      `"document:roadmap#viewer@team:eng#member"`, optionally followed by
      `[expiration:2027-01-01T00:00:00Z]`.

  Ids are 1 to 1024 characters from `A-Z`, `a-z`, `0-9`, and `/_|=-+`.
  `Licet.Relationship` parses and prints the relationship format.

  ## Consistency

  Writes return a token. Reads take a `:consistency` option: `:minimize_latency`
  (the default), `{:at_least, token}`, `{:exact, token}`, or `:full`. See
  [Consistency](consistency.md).

  ## Transactions

  Writes join the caller's `Repo.transaction/2` when one is open. A check in
  that transaction sees its uncommitted writes. See [Transactions](transactions.md).

  ## Errors

  Every function returns `{:error, %Licet.Error{}}` on failure, with a `reason`
  atom you can match on. `Licet.Error` lists the reasons.
  """

  @typedoc "The name of a running instance, as given in its child spec."
  @type instance :: atom()

  @typedoc "An opaque consistency token returned by writes."
  @type token :: String.t()

  @typedoc "Which snapshot of the data a read sees. See [Consistency](consistency.md)."
  @type consistency ::
          :minimize_latency | {:at_least, token()} | {:exact, token()} | :full

  @typedoc "One relationship change for `write/3`."
  @type update ::
          {:create | :touch | :delete, String.t() | Licet.Relationship.t()}

  @typedoc """
  Selects relationships by any of their fields. Fields that are absent match anything.
  """
  @type filter :: %{
          optional(:resource_type) => String.t(),
          optional(:resource_id) => String.t(),
          optional(:relation) => String.t(),
          optional(:subject_type) => String.t(),
          optional(:subject_id) => String.t(),
          optional(:subject_relation) => String.t()
        }

  use Supervisor

  alias Ecto.Adapters.SQL
  alias Licet.Config
  alias Licet.Dispatch
  alias Licet.Engine
  alias Licet.Engine.Subjects
  alias Licet.Error
  alias Licet.Reader.Postgres
  alias Licet.Relationship
  alias Licet.Revision
  alias Licet.SchemaServer
  alias Licet.Store

  @doc """
  Starts an instance and links it to the current process.

  Usually you add `{Licet, opts}` to a supervision tree instead of calling this
  directly. See the module documentation for the options.

  The instance fails to start if the Licet tables don't exist, or if the
  configured schema is invalid or would strand stored relationships.
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

    children =
      [{Licet.Cache, config}] ++
        Dispatch.registries(config.name) ++
        [
          {SchemaServer, config},
          {Revision, config},
          {Licet.GC, config}
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Applies a batch of relationship updates atomically and returns a token.

  Each update is one of:

    * `{:create, relationship}` stores a new relationship and fails with
      `:already_exists` if it is already stored;
    * `{:touch, relationship}` stores it, or updates the expiration of an
      existing one;
    * `{:delete, relationship}` removes it, and does nothing if it isn't stored.

  A relationship is text such as `"document:1#viewer@user:ada"` or a
  `Licet.Relationship`. Every relationship is validated against the current
  schema before anything is written.

  All updates apply together or not at all. Inside an open `Repo.transaction/2`,
  the write joins it; see [Transactions](transactions.md).

  ## Options

    * `:preconditions` - a list of `{:must_match, filter}` or
      `{:must_not_match, filter}`, checked inside the write's transaction.
      The write fails with `:precondition_failed` if any doesn't hold.
    * `:metadata` - a map stored with the write's transaction record.

  ## Errors

    * `:invalid_relationship` - malformed text, or a subject or expiration the
      relation doesn't allow
    * `:unknown_type`, `:unknown_relation` - not in the schema
    * `:already_exists` - a `:create` of a stored relationship
    * `:precondition_failed` - a precondition didn't hold
    * `:too_many_updates`, `:too_many_preconditions` - over `max_updates` or
      `max_preconditions`
    * `:invalid_filter` - `:preconditions` isn't a list

  ## Examples

      {:ok, token} =
        Licet.write(MyApp.Licet, [
          {:create, "document:1#owner@user:ada"},
          {:touch, "document:1#viewer@team:eng#member"},
          {:delete, "document:1#viewer@user:bob"}
        ])

      # Make Ada the owner only if the document has none yet.
      Licet.write(MyApp.Licet, [{:create, "document:1#owner@user:ada"}],
        preconditions: [
          {:must_not_match, %{resource_type: "document", resource_id: "1", relation: "owner"}}
        ]
      )
  """
  @spec write(instance(), [update()], keyword()) :: {:ok, token()} | {:error, Error.t()}
  def write(name, updates, opts \\ []) when is_list(updates) do
    with {:ok, config} <- fetch(name) do
      do_write(config, name, updates, opts, config.max_updates)
    end
  end

  @doc """
  Deletes every stored relationship that matches `filter` and returns a token.

  The filter must include `:resource_type`, so one call can't wipe every
  relationship by accident. Use it to clean up after a record is deleted, or
  to remove relationships before narrowing the schema.

  Deleted relationships stay readable at older snapshots until garbage
  collection removes them, after `gc_window`.

  ## Options

    * `:metadata` - a map stored with the write's transaction record.

  ## Errors

    * `:invalid_filter` - the filter has no `:resource_type`

  ## Examples

      # Everything about document 1.
      Licet.delete(MyApp.Licet, %{resource_type: "document", resource_id: "1"})

      # Every relationship that names Bob on any document.
      Licet.delete(MyApp.Licet, %{resource_type: "document", subject_type: "user", subject_id: "bob"})
  """
  @spec delete(instance(), filter(), keyword()) :: {:ok, token()} | {:error, Error.t()}
  def delete(name, filter, opts \\ []) when is_map(filter) do
    with {:ok, config} <- fetch(name) do
      metadata = Keyword.get(opts, :metadata, %{})

      transact(config.repo, fn ->
        Store.delete_matching(config.repo, config.prefix, filter, metadata)
      end)
    end
  end

  @doc """
  Returns the stored relationships that match `filter`.

  The filter must name at least one field. Expired relationships aren't
  returned. This reads stored relationships only; to ask whether a subject has
  a permission, use `check/5`.

  ## Options

    * `:consistency` - which snapshot to read. Defaults to `:minimize_latency`.

  ## Errors

    * `:invalid_filter` - the filter is empty
    * `:token_invalid`, `:token_not_committed`, `:snapshot_expired` - see
      [Consistency](consistency.md)

  ## Examples

      {:ok, relationships} = Licet.read(MyApp.Licet, %{resource_type: "document", resource_id: "1"})
      Enum.map(relationships, &Licet.Relationship.to_string/1)
      #=> ["document:1#owner@user:ada", "document:1#viewer@user:bob"]
  """
  @spec read(instance(), filter(), keyword()) :: {:ok, [Relationship.t()]} | {:error, Error.t()}
  def read(name, filter, opts \\ []) when is_map(filter) do
    with {:ok, config} <- fetch(name),
         {:ok, revision} <-
           Revision.resolve(config, Keyword.get(opts, :consistency, :minimize_latency)) do
      Store.read(config.repo, config.prefix, revision, filter)
    end
  end

  @doc """
  Checks whether `subject` has `permission` on `resource`.

  `resource` is an object such as `"document:1"`. `permission` is a permission
  or relation of the resource's type. `subject` is an object such as
  `"user:ada"`, or a userset such as `"team:eng#member"`.

  Returns `{:ok, :allowed}` or `{:ok, :denied}`. Treat `{:error, _}` as a
  denial.

  ## Options

    * `:consistency` - which snapshot to read. Defaults to `:minimize_latency`,
      which is cached and can be a few seconds behind the latest write.

  ## Errors

    * `:invalid_relationship` - malformed object text, or a wildcard resource
    * `:unknown_type`, `:unknown_relation` - not in the schema
    * `:depth_exceeded`, `:cycle` - the evaluation went deeper than `max_depth`
      or revisited itself
    * `:timeout` - longer than the instance `timeout`
    * `:token_invalid`, `:token_not_committed`, `:snapshot_expired` - see
      [Consistency](consistency.md)

  ## Examples

      Licet.check(MyApp.Licet, "document:1", "view", "user:ada")
      #=> {:ok, :allowed}

      Licet.check(MyApp.Licet, "document:1", "view", "user:bob", consistency: {:at_least, token})
      #=> {:ok, :denied}
  """
  @spec check(instance(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, :allowed | :denied} | {:error, Error.t()}
  def check(name, resource, permission, subject, opts \\ []) do
    meta = %{resource: resource, permission: permission, subject: subject}

    :telemetry.span([:licet, :check], meta, fn ->
      {do_check(name, resource, permission, subject, opts), meta}
    end)
  end

  @doc """
  Runs several checks at one snapshot.

  Each check is a map with `:resource`, `:permission`, and `:subject`, as in
  `check/5`. The results come back in the same order. A failing check returns
  its own `{:error, _}` without stopping the others; the call as a whole fails
  only when the snapshot can't be resolved.

  All checks read the same snapshot, so their answers are consistent with each
  other.

  ## Options

    * `:consistency` - which snapshot to read. Defaults to `:minimize_latency`.

  ## Examples

      Licet.check_bulk(MyApp.Licet, [
        %{resource: "document:1", permission: "view", subject: "user:ada"},
        %{resource: "document:2", permission: "view", subject: "user:ada"},
        %{resource: "document:*", permission: "view", subject: "user:ada"}
      ])
      #=> {:ok, [{:ok, :allowed}, {:ok, :denied}, {:error, %Licet.Error{reason: :invalid_relationship}}]}
  """
  @spec check_bulk(instance(), [map()], keyword()) :: {:ok, [result]} | {:error, Error.t()}
        when result: {:ok, :allowed | :denied} | {:error, Error.t()}
  def check_bulk(name, checks, opts \\ []) when is_list(checks) do
    with {:ok, prepared} <- prepare(name, opts) do
      {:ok, run_bulk(prepared, checks)}
    end
  end

  @doc """
  Lists the ids of resources of `type` on which `subject` has `permission`.

  Use it to filter a list page to what the current user may see. Ids are
  returned as strings, sorted, one page at a time. The third element is a
  cursor for the next page, or `nil` on the last page.

  The full result is computed before a page is returned, and the call fails
  with `:lookup_too_large` when it exceeds the instance `max_lookup`.

  ## Options

    * `:limit` - the page size. Defaults to 100.
    * `:cursor` - the cursor from the previous page.
    * `:consistency` - which snapshot to read. Defaults to `:minimize_latency`.
      Pass the same value for every page.

  ## Errors

    * `:invalid_relationship` - malformed subject text
    * `:unknown_type`, `:unknown_relation` - not in the schema
    * `:lookup_too_large`, `:depth_exceeded`, `:timeout` - over an instance limit
    * `:invalid_filter` - a malformed cursor

  ## Examples

      {:ok, ids, cursor} = Licet.lookup_resources(MyApp.Licet, "document", "view", "user:ada", limit: 2)
      #=> {:ok, ["1", "2"], "v1.IjIi"}

      {:ok, more, nil} =
        Licet.lookup_resources(MyApp.Licet, "document", "view", "user:ada", limit: 2, cursor: cursor)
  """
  @spec lookup_resources(instance(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [String.t()], String.t() | nil} | {:error, Error.t()}
  def lookup_resources(name, type, permission, subject, opts \\ []) do
    meta = %{resource_type: type, permission: permission, subject: subject}

    :telemetry.span([:licet, :lookup], meta, fn ->
      {do_lookup_resources(name, type, permission, subject, opts), meta}
    end)
  end

  @doc """
  Lists the subjects of `subject_type` that have `permission` on `resource`.

  Use it to show who has access, for example in a sharing dialog.
  `subject_type` is an object type such as `"user"`, or a userset type such as
  `"team#member"`.

  Each result is a map with the `subject` and the subjects it `excluded`. Only
  a wildcard excludes anything: `%{subject: "user:*", excluded: ["user:dan"]}`
  means every user except Dan. Concrete subjects are listed even when a
  wildcard also covers them. A userset counts as a member of itself, so
  `"team:eng#member"` is listed for `"team#member"` when the permission
  reaches it. This matches SpiceDB's LookupSubjects.

  Results are sorted by subject and paginated like `lookup_resources/5`.

  ## Options

    * `:limit` - the page size. Defaults to 100.
    * `:cursor` - the cursor from the previous page.
    * `:consistency` - which snapshot to read. Defaults to `:minimize_latency`.

  ## Errors

    * `:invalid_relationship` - malformed resource text
    * `:invalid_filter` - a malformed subject type or cursor
    * `:unknown_type`, `:unknown_relation` - not in the schema
    * `:lookup_too_large`, `:depth_exceeded`, `:timeout` - over an instance limit

  ## Examples

      Licet.lookup_subjects(MyApp.Licet, "document:1", "view", "user")
      #=> {:ok, [%{subject: "user:*", excluded: ["user:dan"]}, %{subject: "user:tom", excluded: []}], nil}

      Licet.lookup_subjects(MyApp.Licet, "document:1", "view", "team#member")
      #=> {:ok, [%{subject: "team:eng#member", excluded: []}], nil}
  """
  @spec lookup_subjects(instance(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [%{subject: String.t(), excluded: [String.t()]}], String.t() | nil}
          | {:error, Error.t()}
  def lookup_subjects(name, resource, permission, subject_type, opts \\ []) do
    meta = %{resource: resource, permission: permission, subject_type: subject_type}

    :telemetry.span([:licet, :lookup], meta, fn ->
      {do_lookup_subjects(name, resource, permission, subject_type, opts), meta}
    end)
  end

  @doc """
  Runs a check and returns how it was decided.

  Takes the same arguments and options as `check/5`, and returns the answer
  with a trace. Each trace node is a map with the `:resource` and
  `:permission` it evaluated, its `:result`, and the `:children` evaluated
  beneath it.

  Explain never uses the cache and evaluates arrows sequentially, so it's
  slower than `check/5`. Use it for debugging.

  ## Examples

      Licet.explain(MyApp.Licet, "document:1", "view", "user:ada")
      #=> {:ok, :allowed,
      #=>  %{resource: "document:1", permission: "view", result: :allowed, children: [...]}}
  """
  @spec explain(instance(), String.t(), String.t(), String.t(), keyword()) ::
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
  Replaces the schema at runtime and returns a token.

  The new schema is parsed, then compared with the stored relationships. It is
  rejected with `:unsafe_schema_change` if it would leave some of them
  meaningless: a removed definition or relation that still has relationships,
  `use expiration` removed while relationships carry an expiry, or a relation
  that no longer accepts a subject type it still has. Adding definitions,
  relations, permissions, and subject types is always accepted.

  Most applications set the schema with the `:schema` option instead, which
  applies the same rules at startup. See [Operations](operations.md).

  ## Options

    * `:metadata` - a map stored with the write's transaction record.

  ## Errors

    * `:invalid_schema` - the text doesn't parse; `details` has the line and column
    * `:unsafe_schema_change` - the change would strand stored relationships

  ## Examples

      {:ok, token} = Licet.write_schema(MyApp.Licet, File.read!("priv/licet/schema.zed"))
  """
  @spec write_schema(instance(), String.t(), keyword()) :: {:ok, token()} | {:error, Error.t()}
  def write_schema(name, source, opts \\ []) when is_binary(source) do
    with {:ok, config} <- fetch(name),
         {:ok, parsed} <- Licet.Schema.parse(source),
         {:ok, old} <- current_parsed(config) do
      metadata = Keyword.get(opts, :metadata, %{})

      result =
        transact(config.repo, fn -> store_schema(config, old, parsed, source, metadata) end)

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
  Creates many relationships in one transaction and returns a token.

  Like `write/3` with only `:create` updates, but limited by the instance
  `max_import` (10,000 by default) instead of `max_updates`. Use it to load
  existing data, for example when migrating from SpiceDB. The whole batch fails
  with `:already_exists` if any relationship is already stored.

  Takes the same options and returns the same errors as `write/3`.

  ## Examples

      Licet.import(MyApp.Licet, [
        "document:1#owner@user:ada",
        "document:2#owner@user:ada",
        "document:2#viewer@team:eng#member"
      ])
  """
  @spec import(instance(), [String.t() | Relationship.t()], keyword()) ::
          {:ok, token()} | {:error, Error.t()}
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
         {:ok, preconditions} <- normalize_preconditions(opts, config.max_preconditions) do
      span_write(
        config,
        updates,
        normalized,
        preconditions,
        Keyword.get(opts, :metadata, %{}),
        schema
      )
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

  defp do_lookup_subjects(name, resource, permission, subject_type, opts) do
    with {:ok, prepared} <- prepare(name, opts),
         {:ok, resource} <- object(resource, false),
         {:ok, subject_type} <- subject_type(subject_type),
         {:ok, set} <-
           Engine.subject_set(
             prepared.schema,
             prepared.reader,
             prepared.revision,
             resource.type,
             resource.id,
             permission,
             subject_type,
             prepared.opts
           ) do
      found = Map.new(Subjects.to_list(set), &format_found/1)

      with {:ok, page, cursor} <-
             Licet.Page.slice(
               Map.keys(found),
               Keyword.get(opts, :cursor),
               Keyword.get(opts, :limit, 100)
             ) do
        {:ok, Enum.map(page, &%{subject: &1, excluded: Map.fetch!(found, &1)}), cursor}
      end
    end
  end

  defp subject_type(value) when is_binary(value) do
    {type, relation} =
      case String.split(value, "#", parts: 2) do
        [type, relation] -> {type, relation}
        [type] -> {type, ""}
      end

    if Relationship.valid_type?(type) and
         (relation == "" or Relationship.valid_relation?(relation)),
       do: {:ok, {type, relation}},
       else: {:error, Error.new(:invalid_filter, "invalid subject type #{inspect(value)}")}
  end

  defp subject_type(other),
    do: {:error, Error.new(:invalid_filter, "invalid subject type #{inspect(other)}")}

  defp format_found(%{subject: {type, id, relation}, excluded: excluded}) do
    {format_subject({type, id, relation}),
     Enum.map(excluded, &format_subject({type, &1, relation}))}
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
      max_lookup: config.max_lookup
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
    key = cache_key(prepared, {resource, permission, subject})

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

  defp cache_key(%{revision: %{snapshot: snapshot, own_xid: own_xid, at: at}}, check) do
    {resource, permission, subject} = check
    {{snapshot, own_xid, at}, resource, permission, subject}
  end

  # Checks that share a resource type, permission, and subject are answered
  # together, one query per level of the graph.
  defp run_bulk(prepared, checks) do
    parsed = Enum.map(checks, &bulk_item/1)
    valid = for({:ok, check} <- parsed, do: check) |> Enum.uniq()
    {hits, misses} = bulk_cached(prepared, valid)

    answers =
      misses
      |> Enum.group_by(fn {resource, permission, subject} ->
        {resource.type, permission, subject}
      end)
      |> Enum.reduce(hits, fn {group, group_checks}, acc ->
        Map.merge(acc, bulk_group(prepared, group, group_checks))
      end)

    Enum.map(parsed, fn
      {:ok, check} -> Map.fetch!(answers, check)
      {:error, error} -> {:error, error}
    end)
  end

  defp bulk_item(check) do
    with {:ok, resource} <- object(check.resource, false),
         {:ok, subject} <- object(check.subject, true) do
      {:ok, {resource, check.permission, subject}}
    end
  end

  defp bulk_cached(%{revision: %{cache?: false}}, checks), do: {%{}, checks}

  defp bulk_cached(prepared, checks) do
    Enum.reduce(checks, {%{}, []}, fn check, {hits, misses} ->
      case Dispatch.cached(prepared.config.name, cache_key(prepared, check)) do
        {:ok, value} -> {Map.put(hits, check, {:ok, value}), misses}
        :miss -> {hits, [check | misses]}
      end
    end)
  end

  defp bulk_group(prepared, {type, permission, subject}, checks) do
    ids = Enum.map(checks, fn {resource, _permission, _subject} -> resource.id end)

    results =
      Engine.check_set(
        prepared.schema,
        prepared.reader,
        prepared.revision,
        type,
        ids,
        permission,
        subject,
        prepared.opts
      )

    Map.new(checks, fn {resource, _permission, _subject} = check ->
      {check, bulk_store(prepared, check, Map.fetch!(results, resource.id))}
    end)
  end

  defp bulk_store(_prepared, _check, {:error, error}), do: {:error, error}
  defp bulk_store(%{revision: %{cache?: false}}, _check, answer), do: {:ok, answer}

  defp bulk_store(prepared, check, answer),
    do: Dispatch.put(prepared.config.name, cache_key(prepared, check), {:ok, answer})

  defp object(value, allow_wildcard) do
    case Relationship.parse_object(value) do
      {:ok, _type, "*", _relation} when not allow_wildcard ->
        {:error, Error.new(:invalid_relationship, "resource cannot be a wildcard")}

      {:ok, type, id, relation} ->
        {:ok, %{type: type, id: id, relation: relation}}

      {:error, %Error{} = error} ->
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

  defp normalize_preconditions(opts, max) do
    case Keyword.get(opts, :preconditions, []) do
      preconditions when not is_list(preconditions) ->
        {:error, Error.new(:invalid_filter, "preconditions must be a list")}

      preconditions when length(preconditions) > max ->
        {:error, Error.new(:too_many_preconditions, "expected at most #{max} preconditions")}

      preconditions ->
        {:ok, preconditions}
    end
  end

  defp current_parsed(config) do
    with {:ok, source} <- Store.current_schema(config.repo, config.prefix) do
      parse_current(source)
    end
  end

  defp parse_current(nil), do: {:ok, nil}
  defp parse_current(source), do: Licet.Schema.parse(source)

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
    if in_transaction?(repo) do
      savepoint(repo, fun)
    else
      repo.transaction(fn -> unwrap_or_rollback(repo, fun.()) end)
    end
  end

  defp unwrap_or_rollback(_repo, {:ok, value}), do: value
  defp unwrap_or_rollback(repo, {:error, error}), do: repo.rollback(error)

  # Inside the caller's transaction a failed write is undone back to a
  # savepoint, so the caller decides whether the whole transaction fails.
  defp savepoint(repo, fun) do
    SQL.query!(repo, "SAVEPOINT licet_write", [])

    case fun.() do
      {:ok, value} ->
        SQL.query!(repo, "RELEASE SAVEPOINT licet_write", [])
        {:ok, value}

      {:error, error} ->
        SQL.query!(repo, "ROLLBACK TO SAVEPOINT licet_write", [])
        {:error, error}
    end
  end

  defp in_transaction?(repo) do
    repo
    |> Ecto.Adapter.lookup_meta()
    |> SQL.in_transaction?()
  end

  defp store_schema(config, old, parsed, source, metadata) do
    with :ok <- Store.ensure_compatible(config.repo, config.prefix, old, parsed) do
      Store.write_schema(config.repo, config.prefix, source, parsed.hash, metadata)
    end
  end

  defp span_write(config, updates, normalized, preconditions, metadata, schema) do
    :telemetry.span([:licet, :write], %{count: length(updates)}, fn ->
      result = write_rows(config, normalized, preconditions, metadata, schema)
      {result, %{count: length(updates)}}
    end)
  end

  defp write_rows(config, normalized, preconditions, metadata, schema) do
    transact(config.repo, fn ->
      Store.write(config.repo, config.prefix, normalized, preconditions, metadata, schema)
    end)
  end
end
