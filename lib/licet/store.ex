defmodule Licet.Store do
  @moduledoc """
  Postgres storage for relationships, schema versions, and revision snapshots.
  """

  alias Ecto.Adapters.SQL
  alias Licet.Error
  alias Licet.Relationship
  alias Licet.Rules
  alias Licet.Schema.Diff
  alias Licet.Token

  @prefix ~r/^[a-z_][a-z0-9_]{0,62}$/

  @spec migrated?(module(), String.t()) :: boolean()
  def migrated?(repo, prefix) do
    sql =
      "SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'relationships'"

    match?({:ok, %{rows: [[1]]}}, query(repo, sql, [prefix!(prefix)]))
  end

  @spec list_relationships(module(), String.t(), map()) :: [Relationship.t()]
  def list_relationships(repo, prefix, filter) do
    prefix = prefix!(prefix)
    params = [filter.snapshot, own(filter), filter.at]
    {extra, params} = filter_clause(filter, params)

    sql = """
    SELECT resource_type, resource_id, relation, subject_type, subject_id, subject_relation, expires_at
    FROM #{prefix}.relationships
    WHERE #{visible()} #{extra}
    """

    %{rows: rows} = query!(repo, sql, params)
    Enum.map(rows, &row_to_relationship/1)
  end

  @spec read(module(), String.t(), map(), map()) ::
          {:ok, [Relationship.t()]} | {:error, Error.t()}
  def read(repo, prefix, revision, filter) do
    if blank?(filter) do
      {:error, Error.new(:invalid_filter, "read requires a filter")}
    else
      {:ok, list_relationships(repo, prefix, Map.merge(revision_filter(revision), filter))}
    end
  end

  @spec write(module(), String.t(), list(), list(), map(), map()) ::
          {:ok, Token.t()} | {:error, Error.t()}
  def write(repo, prefix, updates, preconditions, metadata, schema) do
    with :ok <- validate_all(schema, updates),
         {:ok, revision} <- assign(repo),
         :ok <- insert_transaction(repo, prefix, revision, metadata),
         :ok <- check_preconditions(repo, prefix, revision, preconditions),
         :ok <- apply_all(repo, prefix, revision, updates) do
      {:ok, encode(revision)}
    end
  end

  @spec delete_matching(module(), String.t(), map(), map()) ::
          {:ok, Token.t()} | {:error, Error.t()}
  def delete_matching(repo, prefix, filter, metadata) do
    with :ok <- require_type(filter),
         {:ok, revision} <- assign(repo),
         :ok <- insert_transaction(repo, prefix, revision, metadata),
         :ok <- tombstone_filter(repo, prefix, revision.xid, filter) do
      {:ok, encode(revision)}
    end
  end

  @spec current_schema(module(), String.t()) :: {:ok, String.t() | nil}
  def current_schema(repo, prefix) do
    prefix = prefix!(prefix)

    sql =
      "SELECT source FROM #{prefix}.schemas WHERE deleted_xid IS NULL ORDER BY version DESC LIMIT 1"

    with {:ok, %{rows: rows}} <- query(repo, sql, []) do
      case rows do
        [[source]] -> {:ok, source}
        [] -> {:ok, nil}
      end
    end
  end

  @spec write_schema(module(), String.t(), String.t(), String.t(), map()) ::
          {:ok, Token.t()} | {:error, Error.t()}
  def write_schema(repo, prefix, source, hash, metadata) do
    with {:ok, revision} <- assign(repo),
         :ok <- insert_transaction(repo, prefix, revision, metadata),
         :ok <- tombstone_schema(repo, prefix, revision.xid),
         :ok <- insert_schema(repo, prefix, source, hash, revision.xid) do
      {:ok, encode(revision)}
    end
  end

  @spec ensure_compatible(module(), String.t(), map() | nil, map()) :: :ok | {:error, Error.t()}
  def ensure_compatible(_repo, _prefix, nil, _new), do: :ok

  def ensure_compatible(repo, prefix, old, new) do
    changes = Diff.changes(old, new)

    case conflict(repo, prefix, old, new, changes) do
      nil -> :ok
      reason -> {:error, Error.new(:unsafe_schema_change, reason)}
    end
  end

  @spec current_revision(module()) :: {:ok, map()} | {:error, Error.t()}
  def current_revision(repo) do
    sql =
      "SELECT pg_current_snapshot()::text, clock_timestamp(), COALESCE(pg_current_xact_id_if_assigned()::text, '')"

    with {:ok, %{rows: [[snapshot, at, own]]}} <- query(repo, sql, []) do
      {:ok, %{snapshot: snapshot, at: at, own_xid: own, xid: own}}
    end
  end

  @spec xact_status(module(), String.t()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def xact_status(repo, xid) do
    with {:ok, %{rows: [[status]]}} <-
           query(repo, "SELECT pg_xact_status($1::text::xid8)::text", [xid]) do
      {:ok, status}
    end
  end

  @spec fetch_transaction(module(), String.t(), String.t()) ::
          {:ok, map() | nil} | {:error, Error.t()}
  def fetch_transaction(repo, prefix, xid) do
    prefix = prefix!(prefix)

    sql =
      "SELECT snapshot::text, inserted_at FROM #{prefix}.transactions WHERE xid = $1::text::xid8"

    with {:ok, %{rows: rows}} <- query(repo, sql, [xid]) do
      transaction_row(rows, xid)
    end
  end

  @spec xid_visible?(module(), String.t(), String.t()) :: {:ok, boolean()} | {:error, Error.t()}
  def xid_visible?(repo, xid, snapshot) do
    sql = "SELECT pg_visible_in_snapshot($1::text::xid8, $2::text::pg_snapshot)"

    with {:ok, %{rows: [[visible]]}} <- query(repo, sql, [xid, snapshot]) do
      {:ok, visible}
    end
  end

  @spec collect(module(), String.t(), pos_integer(), pos_integer()) :: :ok | {:error, Error.t()}
  def collect(repo, prefix, window, batch) do
    prefix = prefix!(prefix)

    with {:ok, xmin} <- horizon(repo, prefix, window),
         :ok <- delete_batches(repo, prefix, tombstone_sql(prefix), [xmin, batch]),
         :ok <- delete_batches(repo, prefix, expired_sql(prefix), [window, batch]) do
      delete_batches(repo, prefix, transaction_sql(prefix), [window, batch])
    end
  end

  @spec try_lock(module(), integer()) :: {:ok, boolean()} | {:error, Error.t()}
  def try_lock(repo, key) do
    with {:ok, %{rows: [[got]]}} <- query(repo, "SELECT pg_try_advisory_lock($1::bigint)", [key]) do
      {:ok, got}
    end
  end

  @spec unlock(module(), integer()) :: :ok
  def unlock(repo, key) do
    _ = query(repo, "SELECT pg_advisory_unlock($1::bigint)", [key])
    :ok
  end

  defp assign(repo) do
    with {:ok, %{rows: [[xid]]}} <- query(repo, "SELECT pg_current_xact_id()::text", []),
         {:ok, %{rows: [[snapshot, at]]}} <-
           query(repo, "SELECT pg_current_snapshot()::text, clock_timestamp()", []) do
      {:ok, %{xid: xid, snapshot: snapshot, own_xid: xid, at: at}}
    end
  end

  defp insert_transaction(repo, prefix, revision, metadata) do
    with {:ok, row} <- fetch_transaction(repo, prefix, revision.xid) do
      if row do
        :ok
      else
        insert_transaction_row(repo, prefix, revision, metadata)
      end
    end
  end

  defp insert_transaction_row(repo, prefix, revision, metadata) do
    prefix = prefix!(prefix)

    sql = """
    INSERT INTO #{prefix}.transactions (xid, snapshot, inserted_at, metadata)
    VALUES ($1::text::xid8, $2::text::pg_snapshot, $3, $4::jsonb)
    """

    with {:ok, _} <-
           query(repo, sql, [
             revision.xid,
             revision.snapshot,
             revision.at,
             Jason.encode!(metadata)
           ]) do
      :ok
    end
  end

  defp validate_all(schema, updates) do
    Enum.reduce_while(updates, :ok, fn {_action, rel}, :ok ->
      case Rules.relationship(schema, rel) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp check_preconditions(repo, prefix, revision, preconditions) do
    Enum.reduce_while(preconditions, :ok, fn precondition, :ok ->
      case precondition(repo, prefix, revision, precondition) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp precondition(repo, prefix, revision, {op, filter}) do
    rows = list_relationships(repo, prefix, Map.merge(revision_filter(revision), filter))
    matches = rows != []

    case {op, matches} do
      {:must_match, true} -> :ok
      {:must_not_match, false} -> :ok
      _ -> {:error, Error.new(:precondition_failed, "precondition failed")}
    end
  end

  defp apply_all(repo, prefix, revision, updates) do
    Enum.reduce_while(updates, :ok, fn update, :ok ->
      case apply_one(repo, prefix, revision, update) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp apply_one(repo, prefix, revision, {:create, rel}) do
    case living(repo, prefix, rel) do
      nil -> insert_row(repo, prefix, revision, rel)
      %{} -> {:error, Error.new(:already_exists, "relationship already exists")}
    end
  end

  defp apply_one(repo, prefix, revision, {:touch, rel}) do
    case living(repo, prefix, rel) do
      nil -> insert_row(repo, prefix, revision, rel)
      row -> retouch(repo, prefix, revision, rel, row)
    end
  end

  defp apply_one(repo, prefix, revision, {:delete, rel}) do
    tombstone(repo, prefix, revision.xid, rel)
  end

  defp same_expiry?(left, right), do: left == right

  defp insert_row(repo, prefix, revision, rel) do
    prefix = prefix!(prefix)

    sql = """
    INSERT INTO #{prefix}.relationships
      (resource_type, resource_id, relation, subject_type, subject_id, subject_relation, expires_at, created_xid)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8::text::xid8)
    """

    params = [
      rel.resource_type,
      rel.resource_id,
      rel.relation,
      rel.subject_type,
      rel.subject_id,
      rel.subject_relation,
      rel.expires_at,
      revision.xid
    ]

    with {:ok, _} <- query(repo, sql, params) do
      :ok
    end
  end

  defp living(repo, prefix, rel) do
    prefix = prefix!(prefix)

    sql = """
    SELECT expires_at FROM #{prefix}.relationships
    WHERE deleted_xid IS NULL
      AND resource_type = $1 AND resource_id = $2 AND relation = $3
      AND subject_type = $4 AND subject_id = $5 AND subject_relation = $6
    """

    params = [
      rel.resource_type,
      rel.resource_id,
      rel.relation,
      rel.subject_type,
      rel.subject_id,
      rel.subject_relation
    ]

    %{rows: rows} = query!(repo, sql, params)

    case rows do
      [[expires_at]] -> %{expires_at: expires_at}
      [] -> nil
    end
  end

  defp tombstone(repo, prefix, xid, rel) do
    prefix = prefix!(prefix)

    sql = """
    UPDATE #{prefix}.relationships SET deleted_xid = $1::text::xid8
    WHERE deleted_xid IS NULL
      AND resource_type = $2 AND resource_id = $3 AND relation = $4
      AND subject_type = $5 AND subject_id = $6 AND subject_relation = $7
    """

    params = [
      xid,
      rel.resource_type,
      rel.resource_id,
      rel.relation,
      rel.subject_type,
      rel.subject_id,
      rel.subject_relation
    ]

    with {:ok, _} <- query(repo, sql, params) do
      :ok
    end
  end

  defp tombstone_filter(repo, prefix, xid, filter) do
    prefix = prefix!(prefix)
    params = [xid]
    {extra, params} = filter_clause(filter, params)

    sql =
      "UPDATE #{prefix}.relationships SET deleted_xid = $1::text::xid8 WHERE deleted_xid IS NULL #{extra}"

    with {:ok, _} <- query(repo, sql, params) do
      :ok
    end
  end

  defp tombstone_schema(repo, prefix, xid) do
    prefix = prefix!(prefix)
    sql = "UPDATE #{prefix}.schemas SET deleted_xid = $1::text::xid8 WHERE deleted_xid IS NULL"

    with {:ok, _} <- query(repo, sql, [xid]) do
      :ok
    end
  end

  defp insert_schema(repo, prefix, source, hash, xid) do
    prefix = prefix!(prefix)

    sql =
      "INSERT INTO #{prefix}.schemas (source, hash, created_xid) VALUES ($1, $2, $3::text::xid8)"

    with {:ok, _} <- query(repo, sql, [source, hash, xid]) do
      :ok
    end
  end

  defp retouch(repo, prefix, revision, rel, row) do
    if same_expiry?(row.expires_at, rel.expires_at) do
      :ok
    else
      with :ok <- tombstone(repo, prefix, revision.xid, rel) do
        insert_row(repo, prefix, revision, rel)
      end
    end
  end

  defp transaction_row([[snapshot, at]], xid) do
    {:ok, %{snapshot: snapshot, at: at, xid: xid, own_xid: xid}}
  end

  defp transaction_row([], _xid), do: {:ok, nil}

  defp conflict(repo, prefix, old, new, changes) do
    cond do
      reason = definition_conflict(repo, prefix, changes) -> reason
      reason = relation_conflict(repo, prefix, changes) -> reason
      reason = expiration_conflict(repo, prefix, changes) -> reason
      reason = narrowed_conflict(repo, prefix, old, new, changes) -> reason
      true -> nil
    end
  end

  defp definition_conflict(repo, prefix, changes) do
    if Enum.any?(changes.removed_definitions, &exists?(repo, prefix, "resource_type = $1", [&1])) do
      "a removed definition still has relationships"
    end
  end

  defp relation_conflict(repo, prefix, changes) do
    hit =
      Enum.any?(changes.removed_relations, fn {type, relation} ->
        exists?(repo, prefix, "resource_type = $1 AND relation = $2", [type, relation])
      end)

    if hit, do: "a removed relation still has relationships"
  end

  defp expiration_conflict(repo, prefix, %{dropped_expiration: true}) do
    if exists?(repo, prefix, "expires_at IS NOT NULL", []), do: "expiration is still in use"
  end

  defp expiration_conflict(_repo, _prefix, _changes), do: nil

  defp narrowed_conflict(repo, prefix, _old, new, changes) do
    hit =
      Enum.any?(changes.narrowed, fn {type, relation} ->
        subjects = new.definitions[type].relations[relation].subjects
        narrowed?(repo, prefix, type, relation, subjects)
      end)

    if hit, do: "a relation no longer allows a subject that still has relationships"
  end

  defp narrowed?(repo, prefix, type, relation, subjects) do
    {clause, params} = allow_clause(subjects)

    exists?(repo, prefix, "resource_type = $1 AND relation = $2 AND NOT (#{clause})", [
      type,
      relation | params
    ])
  end

  defp allow_clause([]), do: {"FALSE", []}

  defp allow_clause(subjects) do
    Enum.reduce(subjects, {"FALSE", []}, fn subject, {sql, params} ->
      {piece, extra} = subject_sql(subject, length(params) + 3)
      {sql <> " OR " <> piece, params ++ extra}
    end)
  end

  defp subject_sql(%{wildcard: true, relation: nil, type: type}, index) do
    {"(subject_type = $#{index} AND subject_id = '*' AND subject_relation = '')", [type]}
  end

  defp subject_sql(%{relation: nil, type: type}, index) do
    {"(subject_type = $#{index} AND subject_id <> '*' AND subject_relation = '')", [type]}
  end

  defp subject_sql(%{relation: relation, type: type}, index) do
    {"(subject_type = $#{index} AND subject_relation = $#{index + 1})", [type, relation]}
  end

  defp exists?(repo, prefix, clause, params) do
    prefix = prefix!(prefix)
    sql = "SELECT 1 FROM #{prefix}.relationships WHERE deleted_xid IS NULL AND #{clause} LIMIT 1"
    match?(%{rows: [[1]]}, query!(repo, sql, params))
  end

  defp horizon(repo, prefix, window) do
    sql = """
    SELECT COALESCE(
      (SELECT MIN(pg_snapshot_xmin(snapshot)) FROM #{prefix}.transactions
        WHERE inserted_at >= clock_timestamp() - ($1 * interval '1 second')),
      pg_snapshot_xmin(pg_current_snapshot())
    )::text
    """

    with {:ok, %{rows: [[xmin]]}} <- query(repo, sql, [window]) do
      {:ok, xmin}
    end
  end

  defp delete_batches(repo, _prefix, sql, params) do
    batch = List.last(params)

    Enum.reduce_while(1..100, :ok, fn _step, :ok ->
      case query(repo, sql, params) do
        {:ok, %{num_rows: count}} when count < batch -> {:halt, :ok}
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp tombstone_sql(prefix) do
    """
    DELETE FROM #{prefix}.relationships
    WHERE ctid IN (
      SELECT ctid FROM #{prefix}.relationships
      WHERE deleted_xid IS NOT NULL AND deleted_xid < $1::text::xid8
      LIMIT $2
    )
    """
  end

  defp expired_sql(prefix) do
    """
    DELETE FROM #{prefix}.relationships
    WHERE ctid IN (
      SELECT ctid FROM #{prefix}.relationships
      WHERE expires_at IS NOT NULL
        AND expires_at < clock_timestamp() - ($1 * interval '1 second')
      LIMIT $2
    )
    """
  end

  defp transaction_sql(prefix) do
    """
    DELETE FROM #{prefix}.transactions
    WHERE ctid IN (
      SELECT ctid FROM #{prefix}.transactions
      WHERE inserted_at < clock_timestamp() - ($1 * interval '1 second')
        AND xid <> (SELECT xid FROM #{prefix}.transactions ORDER BY inserted_at DESC, xid DESC LIMIT 1)
      LIMIT $2
    )
    """
  end

  defp visible do
    """
    (created_xid::text = $2 OR pg_visible_in_snapshot(created_xid, $1::text::pg_snapshot))
    AND (
      deleted_xid IS NULL
      OR (deleted_xid::text <> $2 AND NOT pg_visible_in_snapshot(deleted_xid, $1::text::pg_snapshot))
    )
    AND (expires_at IS NULL OR expires_at > $3)
    """
  end

  defp filter_clause(filter, params) do
    fields = [
      :resource_type,
      :resource_id,
      :relation,
      :subject_type,
      :subject_id,
      :subject_relation
    ]

    Enum.reduce(fields, {"", params}, fn field, {sql, acc} ->
      case Map.get(filter, field) do
        nil -> {sql, acc}
        value -> {sql <> " AND #{field} = $#{length(acc) + 1}", acc ++ [value]}
      end
    end)
  end

  defp row_to_relationship([
         type,
         id,
         relation,
         subject_type,
         subject_id,
         subject_relation,
         expires_at
       ]) do
    %Relationship{
      resource_type: type,
      resource_id: id,
      relation: relation,
      subject_type: subject_type,
      subject_id: subject_id,
      subject_relation: subject_relation,
      expires_at: expires_at
    }
  end

  defp revision_filter(revision) do
    %{snapshot: revision.snapshot, own_xid: revision.own_xid, at: revision.at}
  end

  defp encode(revision) do
    Token.encode(%{xid: revision.xid, snapshot: revision.snapshot, at: revision.at})
  end

  defp own(filter), do: Map.get(filter, :own_xid) || ""

  defp blank?(filter) do
    not Enum.any?(
      [:resource_type, :resource_id, :relation, :subject_type, :subject_id, :subject_relation],
      &Map.get(filter, &1)
    )
  end

  defp require_type(%{resource_type: type}) when is_binary(type) and type != "", do: :ok

  defp require_type(_filter),
    do: {:error, Error.new(:invalid_filter, "delete requires resource_type")}

  defp prefix!(prefix) do
    if Regex.match?(@prefix, prefix) do
      prefix
    else
      raise Error.new(
              :invalid_config,
              "prefix #{inspect(prefix)} is not a safe Postgres identifier"
            )
    end
  end

  defp query(repo, sql, params) do
    case SQL.query(repo, sql, params) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> exception_result(error)
    end
  end

  @doc false
  @spec exception_result(term()) :: {:error, Error.t()}
  def exception_result(%Postgrex.Error{postgres: %{code: code}})
      when code in [
             :invalid_text_representation,
             :invalid_binary_representation,
             :invalid_parameter_value
           ] do
    {:error, Error.new(:token_invalid, "token is invalid")}
  end

  def exception_result(%Postgrex.Error{postgres: %{code: :unique_violation}}) do
    {:error, Error.new(:already_exists, "relationship already exists")}
  end

  def exception_result(%Postgrex.Error{postgres: %{code: :undefined_table}}) do
    {:error, Error.new(:not_migrated, "licet tables are missing")}
  end

  def exception_result(other), do: raise(other)

  defp query!(repo, sql, params) do
    case query(repo, sql, params) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
