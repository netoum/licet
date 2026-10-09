defmodule Licet.Engine do
  # Evaluates a compiled schema against a relationship reader.
  #
  # The same functions answer checks for Postgres and for the in-memory reader
  # used by `mix licet.validate`.
  @moduledoc false

  alias Licet.Engine.Membership
  alias Licet.Engine.Subjects
  alias Licet.Error

  @type result :: {:ok, :allowed | :denied} | {:error, Error.t()}
  @type trace :: map()

  @doc """
  Returns whether `subject` has `permission` on `resource`.
  """
  @spec check(map(), term(), map(), map(), String.t(), map(), keyword()) :: result()
  def check(schema, reader, revision, resource, permission, subject, opts \\ []) do
    schema
    |> check_set(reader, revision, resource.type, [resource.id], permission, subject, opts)
    |> Map.fetch!(resource.id)
    |> case do
      {:error, error} -> {:error, error}
      answer -> {:ok, answer}
    end
  end

  @doc """
  Returns the check answer and a trace of the relations that were visited.
  """
  @spec explain(map(), term(), map(), map(), String.t(), map(), keyword()) ::
          {:ok, :allowed | :denied, trace()} | {:error, Error.t()}
  def explain(schema, reader, revision, resource, permission, subject, opts \\ []) do
    ctx = context(schema, reader, revision, opts)
    eval(ctx, resource.type, resource.id, permission, subject)
  end

  defp context(schema, reader, revision, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    %{
      schema: schema,
      reader: reader,
      revision: revision,
      stack: [],
      depth: 0,
      max_depth: Keyword.get(opts, :max_depth, 50),
      deadline: System.monotonic_time(:millisecond) + timeout,
      max_lookup: Keyword.get(opts, :max_lookup, 10_000),
      subject_type: nil,
      rows: %{}
    }
  end

  defp eval(ctx, type, id, name, subject) do
    with :ok <- before_eval(ctx, type, id, name),
         {:ok, definition} <- fetch_definition(ctx, type) do
      ctx = %{ctx | stack: [{type, id, name} | ctx.stack]}
      finish(type, id, name, branch(ctx, definition, type, id, name, subject))
    end
  end

  defp finish(type, id, name, {:ok, answer, children}) do
    {:ok, answer, trace(type, id, name, answer, children)}
  end

  defp finish(_type, _id, _name, {:error, error}), do: {:error, error}

  defp before_eval(ctx, type, id, name) do
    cond do
      System.monotonic_time(:millisecond) >= ctx.deadline ->
        {:error, Error.new(:timeout, "check timed out")}

      ctx.depth > ctx.max_depth ->
        {:error, Error.new(:depth_exceeded, "check exceeded max depth of #{ctx.max_depth}")}

      {type, id, name} in ctx.stack ->
        {:error, Error.new(:cycle, "cycle at #{type}:#{id}##{name}")}

      true ->
        :ok
    end
  end

  defp fetch_definition(ctx, type) do
    case Map.get(ctx.schema.definitions, type) do
      nil -> {:error, Error.new(:unknown_type, "unknown type #{type}")}
      definition -> {:ok, definition}
    end
  end

  defp branch(ctx, definition, type, id, name, subject) do
    cond do
      not defined?(definition, name) ->
        {:error, Error.new(:unknown_relation, "unknown relation or permission #{type}##{name}")}

      same_userset?(subject, type, id, name) ->
        {:ok, :allowed, []}

      Map.has_key?(definition.relations, name) ->
        relation(ctx, type, id, name, subject)

      true ->
        expression(ctx, type, id, Map.fetch!(definition.permissions, name), subject)
    end
  end

  defp defined?(definition, name) do
    Map.has_key?(definition.relations, name) or Map.has_key?(definition.permissions, name)
  end

  defp same_userset?(subject, type, id, name) do
    subject.type == type and subject.id == id and subject.relation == name
  end

  defp relation(ctx, type, id, name, subject) do
    found = tuples(ctx, %{resource_type: type, resource_id: id, relation: name})

    if direct?(found, subject),
      do: {:ok, :allowed, []},
      else: walk_usersets(ctx, found, subject)
  end

  defp direct?(tuples, subject) do
    Enum.any?(tuples, fn tuple ->
      tuple.subject_type == subject.type and matching_subject?(tuple, subject)
    end)
  end

  defp matching_subject?(tuple, subject) do
    (tuple.subject_id == subject.id and tuple.subject_relation == subject.relation) or
      (subject.relation == "" and tuple.subject_id == "*" and tuple.subject_relation == "")
  end

  defp walk_usersets(ctx, tuples, subject) do
    tuples
    |> Enum.filter(&userset?/1)
    |> decide(deeper(ctx), fn ctx, tuple ->
      eval(ctx, tuple.subject_type, tuple.subject_id, tuple.subject_relation, subject)
    end)
    |> answers_only()
  end

  defp userset?(tuple) do
    tuple.subject_relation != "" and tuple.subject_id != "*"
  end

  defp expression(ctx, type, id, {:ref, name}, subject) do
    case eval(ctx, type, id, name, subject) do
      {:ok, answer, trace} -> {:ok, answer, [trace]}
      {:error, error} -> {:error, error}
    end
  end

  defp expression(_ctx, _type, _id, :nil_expr, _subject), do: {:ok, :denied, []}

  defp expression(ctx, type, id, {:union, left, right}, subject) do
    combine_union(ctx, type, id, left, right, subject)
  end

  defp expression(ctx, type, id, {:intersection, left, right}, subject) do
    combine_bool(ctx, type, id, left, right, subject, :intersection)
  end

  defp expression(ctx, type, id, {:exclusion, left, right}, subject) do
    combine_bool(ctx, type, id, left, right, subject, :exclusion)
  end

  defp expression(ctx, type, id, {:arrow, left, right}, subject) do
    targets = arrow_targets(deeper(ctx), type, id, left)

    targets
    |> decide(deeper(ctx), fn ctx, {target_type, target_id} ->
      target_expression(ctx, target_type, target_id, right, subject)
    end)
    |> answers_only()
  end

  defp expression(ctx, type, id, {:arrow_all, left, right}, subject) do
    ctx = deeper(ctx)

    case arrow_targets(ctx, type, id, left) do
      [] ->
        {:ok, :denied, []}

      targets ->
        every(targets, fn {target_type, target_id} ->
          target_expression(ctx, target_type, target_id, right, subject)
        end)
    end
  end

  defp target_expression(ctx, type, id, expr, subject) do
    if reachable?(ctx, type, expr),
      do: expression(ctx, type, id, expr, subject),
      else: {:ok, :denied, []}
  end

  defp reachable?(ctx, type, {:ref, name}) do
    case Map.fetch(ctx.schema.definitions, type) do
      {:ok, definition} -> defined?(definition, name)
      :error -> true
    end
  end

  defp reachable?(_ctx, _type, _expr), do: true

  defp every(targets, fun) do
    Enum.reduce_while(targets, {:ok, :allowed, []}, fn target, acc ->
      case fun.(target) do
        {:ok, :allowed, _trace} -> {:cont, acc}
        {:ok, :denied, _trace} -> {:halt, {:ok, :denied, []}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp combine_union(ctx, type, id, left, right, subject) do
    case expression(ctx, type, id, left, subject) do
      {:ok, :allowed, children} ->
        {:ok, :allowed, children}

      {:ok, :denied, left_children} ->
        case expression(ctx, type, id, right, subject) do
          {:ok, answer, right_children} -> {:ok, answer, left_children ++ right_children}
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp combine_bool(ctx, type, id, left, right, subject, op) do
    with {:ok, left_answer, left_children} <- expression(ctx, type, id, left, subject),
         {:ok, right_answer, right_children} <- expression(ctx, type, id, right, subject) do
      answer = bool_answer(op, left_answer, right_answer)
      {:ok, answer, left_children ++ right_children}
    end
  end

  defp bool_answer(:intersection, :allowed, :allowed), do: :allowed
  defp bool_answer(:intersection, _left, _right), do: :denied
  defp bool_answer(:exclusion, :allowed, :denied), do: :allowed
  defp bool_answer(:exclusion, _left, _right), do: :denied

  defp arrow_targets(ctx, type, id, relation) when is_binary(relation) do
    ctx
    |> tuples(%{resource_type: type, resource_id: id, relation: relation})
    |> Enum.flat_map(&arrow_target/1)
  end

  defp arrow_targets(ctx, type, id, {:arrow, left, right}) do
    ctx
    |> arrow_targets(type, id, left)
    |> Enum.flat_map(fn {target_type, target_id} ->
      arrow_targets(ctx, target_type, target_id, right)
    end)
  end

  defp arrow_targets(ctx, type, id, {:ref, name}), do: arrow_targets(ctx, type, id, name)
  defp arrow_targets(_ctx, _type, _id, _other), do: []

  defp arrow_target(%{subject_id: "*"}), do: []
  defp arrow_target(tuple), do: [{tuple.subject_type, tuple.subject_id}]

  defp decide(targets, ctx, fun) when is_list(targets) do
    Enum.reduce_while(targets, {:ok, :denied, []}, fn target, acc ->
      case fun.(ctx, target) do
        {:ok, :allowed, children} when is_list(children) ->
          {:halt, {:ok, :allowed, children}}

        {:ok, :allowed, %{} = trace} ->
          {:halt, {:ok, :allowed, [trace]}}

        {:ok, :denied, _trace} ->
          {:cont, acc}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp answers_only({:ok, answer, children}), do: {:ok, answer, children}
  defp answers_only({:error, error}), do: {:error, error}

  defp deeper(ctx), do: %{ctx | depth: ctx.depth + 1}

  defp tuples(ctx, filter) do
    Licet.Reader.list(ctx.reader, Map.merge(ctx.revision, filter))
  end

  defp trace(type, id, name, answer, children) do
    %{
      resource: type <> ":" <> id,
      permission: name,
      result: answer,
      children: children
    }
  end

  @doc """
  Checks `permission` for `subject` on every id in `ids`, all of `type`.

  Each level of the graph is read for every pending id in one query, and the
  relations one permission reads on the same object are read together. An id
  is allowed as soon as one branch allows it, even if a sibling branch fails,
  and denied as soon as one side of an intersection or exclusion denies it.
  """
  @spec check_set(map(), term(), map(), String.t(), [String.t()], String.t(), map(), keyword()) ::
          %{String.t() => :allowed | :denied | {:error, Error.t()}}
  def check_set(schema, reader, revision, type, ids, permission, subject, opts \\ []) do
    ctx = context(schema, reader, revision, opts)
    items = ids |> Enum.uniq() |> Enum.map(&{make_ref(), &1, MapSet.new()})
    results = eval_set(ctx, type, permission, subject, items)
    Map.new(items, fn {ref, id, _path} -> {id, Map.fetch!(results, ref)} end)
  end

  # An item is `{ref, id, path}`: the path holds the `{type, id, name}` steps
  # that led to it, so a cycle is detected per item as in `eval/5`.
  defp eval_set(ctx, type, name, subject, items) do
    with :ok <- before_set(ctx),
         {:ok, definition} <- fetch_definition(ctx, type),
         :ok <- defined(definition, type, name) do
      {cyclic, items} = Enum.split_with(items, &on_path?(&1, type, name))

      {same, items} =
        Enum.split_with(items, fn {_ref, id, _} -> same_userset?(subject, type, id, name) end)

      items =
        Enum.map(items, fn {ref, id, path} -> {ref, id, MapSet.put(path, {type, id, name})} end)

      cyclic
      |> Map.new(fn {ref, id, _path} ->
        {ref, {:error, Error.new(:cycle, "cycle at #{type}:#{id}##{name}")}}
      end)
      |> Map.merge(fill(same, :allowed))
      |> Map.merge(body_set(ctx, definition, type, name, subject, items))
    else
      {:error, error} -> fill(items, {:error, error})
    end
  end

  defp before_set(ctx) do
    cond do
      System.monotonic_time(:millisecond) >= ctx.deadline ->
        {:error, Error.new(:timeout, "check timed out")}

      ctx.depth > ctx.max_depth ->
        {:error, Error.new(:depth_exceeded, "check exceeded max depth of #{ctx.max_depth}")}

      true ->
        :ok
    end
  end

  defp defined(definition, type, name) do
    if defined?(definition, name),
      do: :ok,
      else:
        {:error, Error.new(:unknown_relation, "unknown relation or permission #{type}##{name}")}
  end

  defp on_path?({_ref, id, path}, type, name), do: MapSet.member?(path, {type, id, name})

  defp body_set(ctx, definition, type, name, subject, items) do
    if Map.has_key?(definition.relations, name) do
      relation_set(ctx, type, name, subject, items)
    else
      expr = Map.fetch!(definition.permissions, name)
      ctx = prefetch(ctx, definition, type, expr, item_ids(items))
      expr_set(ctx, type, expr, subject, items)
    end
  end

  defp relation_set(_ctx, _type, _name, _subject, []), do: %{}

  defp relation_set(ctx, type, name, subject, items) do
    rows = relation_rows(ctx, type, name, item_ids(items))

    {direct, others} =
      Enum.split_with(items, fn {_ref, id, _} -> direct?(Map.get(rows, id, []), subject) end)

    links =
      for {ref, id, path} <- others,
          tuple <- Map.get(rows, id, []),
          userset?(tuple),
          do:
            {ref, {tuple.subject_type, tuple.subject_relation},
             {make_ref(), tuple.subject_id, path}}

    child_results =
      links
      |> Enum.group_by(fn {_ref, group, _child} -> group end, fn {_ref, _group, child} ->
        child
      end)
      |> Enum.reduce(%{}, fn {{child_type, relation}, children}, acc ->
        Map.merge(acc, eval_set(deeper(ctx), child_type, relation, subject, children))
      end)

    direct
    |> fill(:allowed)
    |> Map.merge(any_of(others, links, child_results))
  end

  defp expr_set(_ctx, _type, _expr, _subject, []), do: %{}

  defp expr_set(ctx, type, {:ref, name}, subject, items),
    do: eval_set(ctx, type, name, subject, items)

  defp expr_set(_ctx, _type, :nil_expr, _subject, items), do: fill(items, :denied)

  defp expr_set(ctx, type, {:union, left, right}, subject, items) do
    combine_set(ctx, type, left, right, subject, items, &(&1 != :allowed), &either/2)
  end

  defp expr_set(ctx, type, {:intersection, left, right}, subject, items) do
    combine_set(ctx, type, left, right, subject, items, &(&1 != :denied), &both/2)
  end

  defp expr_set(ctx, type, {:exclusion, left, right}, subject, items) do
    combine_set(ctx, type, left, right, subject, items, &(&1 != :denied), &without/2)
  end

  defp expr_set(ctx, type, {kind, left, right}, subject, items)
       when kind in [:arrow, :arrow_all] do
    targets = arrow_targets_set(ctx, type, item_ids(items), left)
    ctx = deeper(ctx)

    links =
      for {ref, id, path} <- items,
          {target_type, target_id} <- Map.get(targets, id, []),
          do: {ref, target_type, {make_ref(), target_id, path}}

    child_results =
      links
      |> Enum.group_by(fn {_ref, target_type, _child} -> target_type end, fn {_ref, _type, child} ->
        child
      end)
      |> Enum.reduce(%{}, fn {target_type, children}, acc ->
        Map.merge(acc, target_set(ctx, target_type, right, subject, children))
      end)

    if kind == :arrow,
      do: any_of(items, links, child_results),
      else: all_of(items, links, child_results)
  end

  # The right side only runs for the items the left side leaves open.
  defp combine_set(ctx, type, left, right, subject, items, open?, combine) do
    left_results = expr_set(ctx, type, left, subject, items)
    open = Enum.filter(items, fn {ref, _id, _path} -> open?.(Map.fetch!(left_results, ref)) end)
    right_results = expr_set(ctx, type, right, subject, open)

    Map.new(items, fn {ref, _id, _path} ->
      {ref, combine.(Map.fetch!(left_results, ref), Map.get(right_results, ref))}
    end)
  end

  defp either(:allowed, _right), do: :allowed
  defp either(_left, :allowed), do: :allowed
  defp either({:error, _} = error, _right), do: error
  defp either(_left, {:error, _} = error), do: error
  defp either(_left, _right), do: :denied

  defp both(:denied, _right), do: :denied
  defp both(_left, :denied), do: :denied
  defp both({:error, _} = error, _right), do: error
  defp both(_left, {:error, _} = error), do: error
  defp both(_left, _right), do: :allowed

  defp without(:denied, _right), do: :denied
  defp without(_left, :allowed), do: :denied
  defp without({:error, _} = error, _right), do: error
  defp without(_left, {:error, _} = error), do: error
  defp without(_left, _right), do: :allowed

  defp target_set(ctx, type, expr, subject, children) do
    if reachable?(ctx, type, expr),
      do: expr_set(ctx, type, expr, subject, children),
      else: fill(children, :denied)
  end

  defp any_of(items, links, child_results) do
    fold_links(items, links, child_results, :denied, &either/2)
  end

  # `.all()` grants nothing without a target, and otherwise needs every one.
  defp all_of(items, links, child_results) do
    linked = MapSet.new(links, fn {ref, _group, _child} -> ref end)

    items
    |> Enum.reject(fn {ref, _id, _path} -> MapSet.member?(linked, ref) end)
    |> fill(:denied)
    |> Map.merge(
      fold_links(
        Enum.filter(items, &MapSet.member?(linked, elem(&1, 0))),
        links,
        child_results,
        :allowed,
        &both/2
      )
    )
  end

  defp fold_links(items, links, child_results, initial, combine) do
    by_parent =
      Enum.group_by(links, fn {ref, _group, _child} -> ref end, fn {_ref, _group, {child, _, _}} ->
        Map.fetch!(child_results, child)
      end)

    Map.new(items, fn {ref, _id, _path} ->
      {ref, Enum.reduce(Map.get(by_parent, ref, []), initial, &combine.(&2, &1))}
    end)
  end

  defp arrow_targets_set(ctx, type, ids, relation) when is_binary(relation) do
    ctx
    |> relation_rows(type, relation, ids)
    |> Map.new(fn {id, rows} -> {id, Enum.flat_map(rows, &arrow_target/1)} end)
  end

  defp arrow_targets_set(ctx, type, ids, {:ref, name}),
    do: arrow_targets_set(ctx, type, ids, name)

  defp arrow_targets_set(ctx, type, ids, {:arrow, left, right}) do
    first = arrow_targets_set(ctx, type, ids, left)

    next =
      first
      |> Map.values()
      |> List.flatten()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {target_type, target_ids} ->
        {target_type, arrow_targets_set(ctx, target_type, Enum.uniq(target_ids), right)}
      end)

    Map.new(first, fn {id, targets} ->
      {id,
       Enum.flat_map(targets, fn {target_type, target_id} ->
         next |> Map.fetch!(target_type) |> Map.get(target_id, [])
       end)}
    end)
  end

  defp arrow_targets_set(_ctx, _type, _ids, _other), do: %{}

  # Rows already read for this level are reused; anything else is one query.
  defp relation_rows(ctx, type, relation, ids) do
    case Map.get(ctx.rows, {type, relation}) do
      %{ids: covered, by_id: by_id} ->
        if Enum.all?(ids, &MapSet.member?(covered, &1)),
          do: by_id,
          else: read_rows(ctx, type, relation, ids)

      nil ->
        read_rows(ctx, type, relation, ids)
    end
  end

  defp read_rows(ctx, type, relation, ids) do
    ctx
    |> tuples(%{resource_type: type, resource_id: ids, relation: relation})
    |> Enum.group_by(& &1.resource_id)
  end

  defp prefetch(ctx, definition, type, expr, ids) do
    relations =
      definition
      |> local_relations(expr, [])
      |> Enum.uniq()
      |> Enum.reject(&covered?(ctx, type, &1, ids))

    if length(relations) < 2 or ids == [] do
      ctx
    else
      rows =
        tuples(ctx, %{resource_type: type, resource_id: ids, relation: relations})

      covered = MapSet.new(ids)

      Enum.reduce(relations, ctx, fn relation, ctx ->
        by_id = rows |> Enum.filter(&(&1.relation == relation)) |> Enum.group_by(& &1.resource_id)
        %{ctx | rows: Map.put(ctx.rows, {type, relation}, %{ids: covered, by_id: by_id})}
      end)
    end
  end

  defp covered?(ctx, type, relation, ids) do
    case Map.get(ctx.rows, {type, relation}) do
      %{ids: covered} -> Enum.all?(ids, &MapSet.member?(covered, &1))
      nil -> false
    end
  end

  # The relations one permission reads on its own object, through other
  # permissions of the same definition and the first hop of each arrow.
  defp local_relations(definition, {:ref, name}, seen) do
    cond do
      Map.has_key?(definition.relations, name) ->
        [name]

      name in seen ->
        []

      true ->
        local_relations(definition, Map.fetch!(definition.permissions, name), [name | seen])
    end
  end

  defp local_relations(definition, {op, left, right}, seen)
       when op in [:union, :intersection, :exclusion] do
    local_relations(definition, left, seen) ++ local_relations(definition, right, seen)
  end

  defp local_relations(_definition, {kind, left, _right}, _seen)
       when kind in [:arrow, :arrow_all],
       do: first_relation(left)

  defp local_relations(_definition, :nil_expr, _seen), do: []

  defp first_relation(name) when is_binary(name), do: [name]
  defp first_relation({:arrow, left, _right}), do: first_relation(left)
  defp first_relation(_other), do: []

  defp item_ids(items), do: items |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

  defp fill(items, value), do: Map.new(items, fn {ref, _id, _path} -> {ref, value} end)

  @doc false
  @spec lookup_guard(non_neg_integer(), pos_integer()) :: :ok | {:error, Error.t()}
  def lookup_guard(count, max) when count > max do
    {:error, Error.new(:lookup_too_large, "lookup returned more than #{max} subjects")}
  end

  def lookup_guard(_count, _max), do: :ok

  @doc false
  @spec subject_set(
          map(),
          term(),
          map(),
          String.t(),
          String.t(),
          String.t(),
          {String.t(), String.t()},
          keyword()
        ) :: {:ok, Subjects.t()} | {:error, Error.t()}
  def subject_set(
        schema,
        reader,
        revision,
        type,
        id,
        name,
        {subject_type, subject_relation},
        opts
      ) do
    ctx = %{
      context(schema, reader, revision, opts)
      | subject_type: {subject_type, subject_relation}
    }

    with {:ok, set} <- expand_subjects(ctx, type, id, {:ref, name}) do
      {:ok, Subjects.only(set, subject_type, subject_relation)}
    end
  end

  defp expand_subjects(ctx, type, id, expr) do
    with :ok <- before_expand(ctx),
         {:ok, definition} <- fetch_definition(ctx, type) do
      expand_on(ctx, definition, type, id, expr)
    end
  end

  defp before_expand(ctx) do
    cond do
      System.monotonic_time(:millisecond) >= ctx.deadline ->
        {:error, Error.new(:timeout, "lookup timed out")}

      ctx.depth > ctx.max_depth ->
        {:error, Error.new(:depth_exceeded, "lookup exceeded max depth of #{ctx.max_depth}")}

      true ->
        :ok
    end
  end

  defp expand_on(ctx, definition, type, id, {:ref, name}) do
    with {:ok, set} <- expand_ref(ctx, definition, type, id, name) do
      if ctx.subject_type == {type, name},
        do: capped(ctx, Subjects.add(set, type, id, name)),
        else: {:ok, set}
    end
  end

  defp expand_on(_ctx, _definition, _type, _id, :nil_expr), do: {:ok, Subjects.empty()}

  defp expand_on(ctx, _definition, type, id, {:arrow_all, left, right}) do
    ctx = deeper(ctx)

    case arrow_targets(ctx, type, id, left) do
      [] -> {:ok, Subjects.empty()}
      targets -> intersect_targets(ctx, targets, right)
    end
  end

  defp expand_on(ctx, _definition, type, id, {:union, left, right}) do
    with {:ok, left_set} <- expand_subjects(ctx, type, id, left),
         {:ok, right_set} <- expand_subjects(ctx, type, id, right) do
      capped(ctx, Subjects.union(left_set, right_set))
    end
  end

  defp expand_on(ctx, _definition, type, id, {:intersection, left, right}) do
    with {:ok, left_set} <- expand_subjects(ctx, type, id, left),
         {:ok, right_set} <- expand_subjects(ctx, type, id, right) do
      capped(ctx, Subjects.intersection(left_set, right_set))
    end
  end

  defp expand_on(ctx, _definition, type, id, {:exclusion, left, right}) do
    with {:ok, left_set} <- expand_subjects(ctx, type, id, left),
         {:ok, right_set} <- expand_subjects(ctx, type, id, right) do
      capped(ctx, Subjects.difference(left_set, right_set))
    end
  end

  defp expand_on(ctx, _definition, type, id, {:arrow, left, right}) do
    ctx = deeper(ctx)

    ctx
    |> arrow_targets(type, id, left)
    |> Enum.reduce_while({:ok, Subjects.empty()}, fn {target_type, target_id}, {:ok, acc} ->
      case target_subjects(ctx, target_type, target_id, right) do
        {:ok, set} -> keep(capped(ctx, Subjects.union(acc, set)))
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp expand_ref(ctx, definition, type, id, name) do
    cond do
      Map.has_key?(definition.relations, name) ->
        expand_relation(ctx, type, id, name)

      Map.has_key?(definition.permissions, name) ->
        expand_subjects(ctx, type, id, Map.fetch!(definition.permissions, name))

      true ->
        {:error, Error.new(:unknown_relation, "unknown relation or permission #{type}##{name}")}
    end
  end

  defp intersect_targets(ctx, targets, expr) do
    Enum.reduce_while(targets, {:ok, nil}, fn {target_type, target_id}, {:ok, acc} ->
      ctx
      |> target_subjects(target_type, target_id, expr)
      |> intersect_step(acc)
    end)
  end

  defp target_subjects(ctx, type, id, expr) do
    if reachable?(ctx, type, expr),
      do: expand_subjects(ctx, type, id, expr),
      else: {:ok, Subjects.empty()}
  end

  defp intersect_step({:ok, set}, nil), do: {:cont, {:ok, set}}
  defp intersect_step({:ok, set}, acc), do: {:cont, {:ok, Subjects.intersection(acc, set)}}
  defp intersect_step({:error, error}, _acc), do: {:halt, {:error, error}}

  defp expand_relation(ctx, type, id, name) do
    ctx
    |> tuples(%{resource_type: type, resource_id: id, relation: name})
    |> Enum.reduce_while({:ok, Subjects.empty()}, fn tuple, {:ok, acc} ->
      case include_tuple(deeper(ctx), acc, tuple) do
        {:ok, set} -> keep(capped(ctx, set))
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp include_tuple(_ctx, acc, %{subject_relation: ""} = tuple) do
    {:ok, Subjects.add(acc, tuple.subject_type, tuple.subject_id)}
  end

  defp include_tuple(ctx, acc, tuple) do
    case expand_subjects(
           ctx,
           tuple.subject_type,
           tuple.subject_id,
           {:ref, tuple.subject_relation}
         ) do
      {:ok, set} -> {:ok, Subjects.union(acc, set)}
      {:error, error} -> {:error, error}
    end
  end

  defp capped(ctx, {:ok, set}) do
    case lookup_guard(Subjects.count(set), ctx.max_lookup) do
      :ok -> {:ok, set}
      {:error, error} -> {:error, error}
    end
  end

  defp capped(ctx, %Subjects{} = set), do: capped(ctx, {:ok, set})

  @doc """
  Recursively expands `type:id#name` into every subject it reaches, the way
  SpiceDB's recursive Expand does, and records the relations that hold each one.

  Usersets are subjects in their own right and are also expanded. This is the
  data behind expected relations; checks and lookups do not use it.
  """
  @spec membership(map(), term(), map(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Membership.t()} | {:error, Error.t()}
  def membership(schema, reader, revision, type, id, name, opts \\ []) do
    ctx = context(schema, reader, revision, opts)
    members(ctx, type, id, name)
  end

  defp members(ctx, type, id, name) do
    with :ok <- before_expand(ctx),
         {:ok, definition} <- fetch_definition(ctx, type) do
      cond do
        Map.has_key?(definition.relations, name) ->
          direct_members(ctx, type, id, name)

        Map.has_key?(definition.permissions, name) ->
          members_of(ctx, type, id, Map.fetch!(definition.permissions, name))

        true ->
          {:error, Error.new(:unknown_relation, "unknown relation or permission #{type}##{name}")}
      end
    end
  end

  defp direct_members(ctx, type, id, name) do
    rows = tuples(ctx, %{resource_type: type, resource_id: id, relation: name})
    leaf = Membership.leaf(Enum.map(rows, &subject_of/1), {type, id, name})

    rows
    |> Enum.filter(&(&1.subject_relation != ""))
    |> Enum.reduce_while({:ok, leaf}, fn row, {:ok, acc} ->
      ctx
      |> deeper()
      |> members(row.subject_type, row.subject_id, row.subject_relation)
      |> union_step(acc)
    end)
  end

  defp subject_of(row), do: {row.subject_type, row.subject_id, row.subject_relation}

  defp members_of(ctx, type, id, {:ref, name}), do: members(deeper(ctx), type, id, name)
  defp members_of(_ctx, _type, _id, :nil_expr), do: {:ok, Membership.empty()}

  defp members_of(ctx, type, id, {op, left, right})
       when op in [:union, :intersection, :exclusion] do
    with {:ok, left_set} <- members_of(ctx, type, id, left),
         {:ok, right_set} <- members_of(ctx, type, id, right) do
      {:ok, combine_members(op, left_set, right_set)}
    end
  end

  defp members_of(ctx, type, id, {:arrow, left, right}) do
    ctx
    |> arrow_targets(type, id, left)
    |> Enum.reduce_while({:ok, Membership.empty()}, fn {target_type, target_id}, {:ok, acc} ->
      ctx |> target_members(target_type, target_id, right) |> union_step(acc)
    end)
  end

  defp members_of(ctx, type, id, {:arrow_all, left, right}) do
    ctx
    |> arrow_targets(type, id, left)
    |> Enum.reduce_while({:ok, nil}, fn {target_type, target_id}, {:ok, acc} ->
      ctx |> target_members(target_type, target_id, right) |> intersect_members_step(acc)
    end)
    |> empty_if_none()
  end

  defp target_members(ctx, type, id, expr) do
    if reachable?(ctx, type, expr),
      do: members_of(ctx, type, id, expr),
      else: {:ok, Membership.empty()}
  end

  defp combine_members(:union, left, right), do: Membership.union(left, right)
  defp combine_members(:intersection, left, right), do: Membership.intersection(left, right)
  defp combine_members(:exclusion, left, right), do: Membership.difference(left, right)

  defp union_step({:ok, set}, acc), do: {:cont, {:ok, Membership.union(acc, set)}}
  defp union_step({:error, error}, _acc), do: {:halt, {:error, error}}

  defp intersect_members_step({:ok, set}, nil), do: {:cont, {:ok, set}}

  defp intersect_members_step({:ok, set}, acc),
    do: {:cont, {:ok, Membership.intersection(acc, set)}}

  defp intersect_members_step({:error, error}, _acc), do: {:halt, {:error, error}}

  defp empty_if_none({:ok, nil}), do: {:ok, Membership.empty()}
  defp empty_if_none(result), do: result

  @doc false
  @spec resource_ids(map(), term(), map(), String.t(), String.t(), map(), keyword()) ::
          {:ok, MapSet.t()} | {:error, Error.t()}
  def resource_ids(schema, reader, revision, resource_type, permission, subject, opts) do
    ctx = context(schema, reader, revision, opts)
    resources_round(ctx, resource_type, permission, subject, %{}, 0)
  end

  # Lookups walk backwards from the subject, like SpiceDB's LookupResources:
  # a relation is read through the subject index, an arrow from the targets
  # already found, so the work follows the answer rather than every resource.
  #
  # A permission that refers back to itself, such as `parent->view`, sees the
  # previous round's set for itself. Rounds repeat until no set changes, which
  # takes one round per level of nesting in the data.
  defp resources_round(ctx, type, name, subject, previous, round) do
    state = %{previous: previous, done: %{}, stack: [], recursive: false}

    with {:ok, ids, state} <- ref_ids(ctx, type, name, subject, state) do
      cond do
        not state.recursive or state.done == previous ->
          {:ok, ids}

        round >= ctx.max_depth ->
          {:error, Error.new(:depth_exceeded, "lookup exceeded max depth of #{ctx.max_depth}")}

        true ->
          resources_round(ctx, type, name, subject, state.done, round + 1)
      end
    end
  end

  defp ref_ids(ctx, type, name, subject, state) do
    key = {type, name}

    cond do
      Map.has_key?(state.done, key) ->
        {:ok, Map.fetch!(state.done, key), state}

      key in state.stack ->
        {:ok, Map.get(state.previous, key, MapSet.new()), %{state | recursive: true}}

      true ->
        compute_ref(ctx, type, name, subject, state)
    end
  end

  defp compute_ref(ctx, type, name, subject, state) do
    inner = %{state | stack: [{type, name} | state.stack]}

    with :ok <- before_expand(ctx),
         {:ok, definition} <- fetch_definition(ctx, type),
         {:ok, ids, inner} <- ref_body(ctx, definition, type, name, subject, inner),
         {:ok, ids} <- capped_ids(ctx, self_userset(ids, type, name, subject)) do
      {:ok, ids, %{inner | stack: state.stack, done: Map.put(inner.done, {type, name}, ids)}}
    end
  end

  defp ref_body(ctx, definition, type, name, subject, state) do
    cond do
      Map.has_key?(definition.relations, name) ->
        relation_ids(ctx, type, Map.fetch!(definition.relations, name), subject, state)

      Map.has_key?(definition.permissions, name) ->
        expr_ids(ctx, type, Map.fetch!(definition.permissions, name), subject, state)

      true ->
        {:error, Error.new(:unknown_relation, "unknown relation or permission #{type}##{name}")}
    end
  end

  defp self_userset(ids, type, name, subject) do
    if subject.type == type and subject.relation == name,
      do: MapSet.put(ids, subject.id),
      else: ids
  end

  defp relation_ids(ctx, type, relation, subject, state) do
    relation.subjects
    |> Enum.filter(& &1.relation)
    |> Enum.uniq_by(&{&1.type, &1.relation})
    |> Enum.reduce_while({:ok, direct_ids(ctx, type, relation, subject), state}, fn
      allowed, {:ok, acc, state} ->
        case ref_ids(ctx, allowed.type, allowed.relation, subject, state) do
          {:ok, members, state} ->
            filter = %{
              resource_type: type,
              relation: relation.name,
              subject_type: allowed.type,
              subject_relation: allowed.relation
            }

            ids = MapSet.new(ids_with_subjects(ctx, filter, members))
            {:cont, {:ok, MapSet.union(acc, ids), state}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
    end)
  end

  defp direct_ids(ctx, type, relation, subject) do
    filter = %{resource_type: type, relation: relation.name, subject_type: subject.type}

    concrete? =
      Enum.any?(relation.subjects, fn allowed ->
        allowed.type == subject.type and not allowed.wildcard and
          (allowed.relation || "") == subject.relation
      end)

    wildcard? =
      subject.relation == "" and
        Enum.any?(relation.subjects, &(&1.type == subject.type and &1.wildcard))

    concrete = Map.merge(filter, %{subject_id: subject.id, subject_relation: subject.relation})
    wildcard = Map.merge(filter, %{subject_id: "*", subject_relation: ""})
    MapSet.new(ids_if(ctx, concrete?, concrete) ++ ids_if(ctx, wildcard?, wildcard))
  end

  defp ids_if(_ctx, false, _filter), do: []
  defp ids_if(ctx, true, filter), do: ctx |> tuples(filter) |> Enum.map(& &1.resource_id)

  defp ids_with_subjects(ctx, filter, subject_ids) do
    if MapSet.size(subject_ids) == 0,
      do: [],
      else: ids_if(ctx, true, Map.put(filter, :subject_id, MapSet.to_list(subject_ids)))
  end

  defp expr_ids(ctx, type, {:ref, name}, subject, state),
    do: ref_ids(ctx, type, name, subject, state)

  defp expr_ids(_ctx, _type, :nil_expr, _subject, state), do: {:ok, MapSet.new(), state}

  defp expr_ids(ctx, type, {:union, left, right}, subject, state) do
    with {:ok, left_ids, state} <- expr_ids(ctx, type, left, subject, state),
         {:ok, right_ids, state} <- expr_ids(ctx, type, right, subject, state) do
      {:ok, MapSet.union(left_ids, right_ids), state}
    end
  end

  defp expr_ids(ctx, type, {:intersection, left, right}, subject, state) do
    with {:ok, left_ids, state} <- expr_ids(ctx, type, left, subject, state),
         {:ok, right_ids, state} <- expr_ids(ctx, type, right, subject, state) do
      {:ok, MapSet.intersection(left_ids, right_ids), state}
    end
  end

  # A set difference is only safe when the subtracted side is final. When it
  # depends on a permission still being solved, each candidate is checked.
  defp expr_ids(ctx, type, {:exclusion, left, right} = expr, subject, state) do
    with {:ok, left_ids, state} <- expr_ids(ctx, type, left, subject, state),
         {:ok, right_ids, inner} <-
           expr_ids(ctx, type, right, subject, %{state | recursive: false}) do
      state = %{inner | recursive: state.recursive or inner.recursive}

      if inner.recursive,
        do: verified_ids(ctx, type, expr, subject, left_ids, state),
        else: {:ok, MapSet.difference(left_ids, right_ids), state}
    end
  end

  defp expr_ids(ctx, type, {:arrow, _left, _right} = expr, subject, state) do
    {relation, right} = arrow_path(expr)
    arrow_ids(ctx, type, relation, right, subject, state)
  end

  # Resources with at least one target that has the permission are the
  # candidates; each is then checked against every target.
  defp expr_ids(ctx, type, {:arrow_all, left, right} = expr, subject, state) do
    {relation, rest} = arrow_path({:arrow, left, right})

    with {:ok, candidates, state} <- arrow_ids(ctx, type, relation, rest, subject, state) do
      verified_ids(ctx, type, expr, subject, candidates, state)
    end
  end

  defp arrow_path({:arrow, relation, right}) when is_binary(relation), do: {relation, right}

  defp arrow_path({:arrow, {:arrow, left, {:ref, name}}, right}),
    do: arrow_path({:arrow, left, {:arrow, name, right}})

  defp arrow_ids(ctx, type, relation_name, right, subject, state) do
    with {:ok, definition} <- fetch_definition(ctx, type) do
      definition.relations
      |> Map.fetch!(relation_name)
      |> Map.fetch!(:subjects)
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> Enum.filter(&reachable?(ctx, &1, right))
      |> Enum.reduce_while({:ok, MapSet.new(), state}, fn target, {:ok, acc, state} ->
        arrow_step(ctx, type, relation_name, target, right, subject, acc, state)
      end)
    end
  end

  defp arrow_step(ctx, type, relation_name, target, right, subject, acc, state) do
    case target_ids(ctx, target, right, subject, state) do
      {:ok, target_ids, state} ->
        filter = %{resource_type: type, relation: relation_name, subject_type: target}
        ids = MapSet.new(ids_with_subjects(ctx, filter, target_ids))
        {:cont, {:ok, MapSet.union(acc, ids), state}}

      {:error, error} ->
        {:halt, {:error, error}}
    end
  end

  defp target_ids(ctx, type, {:ref, name}, subject, state),
    do: ref_ids(ctx, type, name, subject, state)

  defp target_ids(ctx, type, expr, subject, state) do
    with {:ok, _definition} <- fetch_definition(ctx, type) do
      expr_ids(ctx, type, expr, subject, state)
    end
  end

  defp verified_ids(ctx, type, expr, subject, candidates, state) do
    items = candidates |> Enum.uniq() |> Enum.map(&{make_ref(), &1, MapSet.new()})
    results = expr_set(ctx, type, expr, subject, items)

    Enum.reduce_while(items, {:ok, MapSet.new(), state}, fn {ref, id, _path}, {:ok, acc, state} ->
      case Map.fetch!(results, ref) do
        :allowed -> {:cont, {:ok, MapSet.put(acc, id), state}}
        :denied -> {:cont, {:ok, acc, state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp capped_ids(ctx, %MapSet{} = ids) do
    case lookup_guard(MapSet.size(ids), ctx.max_lookup) do
      :ok -> {:ok, ids}
      {:error, error} -> {:error, error}
    end
  end

  defp keep({:ok, value}), do: {:cont, {:ok, value}}
  defp keep({:error, error}), do: {:halt, {:error, error}}
end
