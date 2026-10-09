defmodule Licet.Engine do
  @moduledoc """
  Evaluates a compiled schema against a relationship reader.

  The same functions answer checks for Postgres and for the in-memory reader
  used by `mix licet.validate`.
  """

  alias Licet.Engine.Subjects
  alias Licet.Error

  @type result :: {:ok, :allowed | :denied} | {:error, Error.t()}
  @type trace :: map()

  @doc """
  Returns whether `subject` has `permission` on `resource`.
  """
  @spec check(map(), term(), map(), map(), String.t(), map(), keyword()) :: result()
  def check(schema, reader, revision, resource, permission, subject, opts \\ []) do
    case evaluate(schema, reader, revision, resource, permission, subject, opts, false) do
      {:ok, answer, _trace} -> {:ok, answer}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Returns the check answer and a trace of the relations that were visited.
  """
  @spec explain(map(), term(), map(), map(), String.t(), map(), keyword()) ::
          {:ok, :allowed | :denied, trace()} | {:error, Error.t()}
  def explain(schema, reader, revision, resource, permission, subject, opts \\ []) do
    evaluate(schema, reader, revision, resource, permission, subject, opts, true)
  end

  @doc false
  @spec collect(Enumerable.t()) :: result()
  def collect(results) do
    Enum.reduce_while(results, {:ok, :denied}, fn item, acc ->
      collect_item(item, acc)
    end)
  end

  defp evaluate(schema, reader, revision, resource, permission, subject, opts, explain) do
    ctx = context(schema, reader, revision, opts, explain)
    eval(ctx, resource.type, resource.id, permission, subject)
  end

  defp context(schema, reader, revision, opts, explain) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    %{
      schema: schema,
      reader: reader,
      revision: revision,
      stack: [],
      depth: 0,
      max_depth: Keyword.get(opts, :max_depth, 50),
      deadline: System.monotonic_time(:millisecond) + timeout,
      parallel: Keyword.get(opts, :parallel),
      explain: explain,
      max_lookup: Keyword.get(opts, :max_lookup, 10_000)
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
      Map.has_key?(definition.relations, name) ->
        relation(ctx, type, id, name, subject)

      Map.has_key?(definition.permissions, name) ->
        expression(ctx, type, id, Map.fetch!(definition.permissions, name), subject)

      true ->
        {:error, Error.new(:unknown_relation, "unknown relation or permission #{type}##{name}")}
    end
  end

  defp relation(ctx, type, id, name, subject) do
    found = tuples(ctx, %{resource_type: type, resource_id: id, relation: name})

    cond do
      direct?(found, subject) ->
        {:ok, :allowed, []}

      subject.relation != "" ->
        {:ok, :denied, []}

      true ->
        walk_usersets(ctx, found, subject)
    end
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
    |> decide(deeper(ctx), fn tuple ->
      eval(deeper(ctx), tuple.subject_type, tuple.subject_id, tuple.subject_relation, subject)
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
    |> decide(deeper(ctx), fn {target_type, target_id} ->
      expression(deeper(ctx), target_type, target_id, right, subject)
    end)
    |> answers_only()
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

  defp arrow_target(%{subject_id: "*", subject_relation: ""}), do: []
  defp arrow_target(%{subject_relation: relation}) when relation != "", do: []

  defp arrow_target(tuple), do: [{tuple.subject_type, tuple.subject_id}]

  defp decide(targets, %{parallel: parallel, explain: false} = ctx, fun)
       when not is_nil(parallel) and is_list(targets) and length(targets) > 1 do
    parent = self()

    parallel.supervisor
    |> Task.Supervisor.async_stream_nolink(
      targets,
      fn target ->
        Licet.Sandbox.allow(parallel.repo, parent)
        fun.(target)
      end,
      ordered: false,
      max_concurrency: 8,
      timeout: remaining(ctx),
      on_timeout: :kill_task
    )
    |> collect()
    |> wrap_children()
  end

  defp decide(targets, _ctx, fun) when is_list(targets) do
    Enum.reduce_while(targets, {:ok, :denied}, fn target, acc ->
      case fun.(target) do
        {:ok, :allowed, _trace} -> {:halt, {:ok, :allowed}}
        {:ok, :denied, _trace} -> {:cont, acc}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> wrap_children()
  end

  defp wrap_children({:ok, answer}), do: {:ok, answer, []}
  defp wrap_children({:error, error}), do: {:error, error}

  defp collect_item({:ok, {:ok, :allowed, _trace}}, _acc), do: {:halt, {:ok, :allowed}}
  defp collect_item({:ok, {:ok, :allowed}}, _acc), do: {:halt, {:ok, :allowed}}
  defp collect_item({:ok, {:ok, :denied, _trace}}, acc), do: {:cont, acc}
  defp collect_item({:ok, {:ok, :denied}}, acc), do: {:cont, acc}
  defp collect_item({:ok, {:error, error}}, _acc), do: {:halt, {:error, error}}

  defp collect_item({:exit, _reason}, _acc),
    do: {:halt, {:error, Error.new(:timeout, "check timed out")}}

  defp answers_only({:ok, answer, children}), do: {:ok, answer, children}
  defp answers_only({:error, error}), do: {:error, error}

  defp deeper(ctx), do: %{ctx | depth: ctx.depth + 1}

  defp remaining(ctx) do
    max(ctx.deadline - System.monotonic_time(:millisecond), 0)
  end

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

  @doc false
  @spec lookup_guard(non_neg_integer(), pos_integer()) :: :ok | {:error, Error.t()}
  def lookup_guard(count, max) when count > max do
    {:error, Error.new(:lookup_too_large, "lookup returned more than #{max} subjects")}
  end

  def lookup_guard(_count, _max), do: :ok

  @doc false
  @spec subject_set(map(), term(), map(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Subjects.t()} | {:error, Error.t()}
  def subject_set(schema, reader, revision, type, id, name, opts) do
    ctx = context(schema, reader, revision, opts, false)
    expand_subjects(ctx, type, id, {:ref, name})
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
    cond do
      Map.has_key?(definition.relations, name) ->
        expand_relation(ctx, type, id, name)

      Map.has_key?(definition.permissions, name) ->
        expand_subjects(ctx, type, id, Map.fetch!(definition.permissions, name))

      true ->
        {:error, Error.new(:unknown_relation, "unknown relation or permission #{type}##{name}")}
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
      case expand_subjects(ctx, target_type, target_id, right) do
        {:ok, set} -> keep(capped(ctx, Subjects.union(acc, set)))
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

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

  defp include_tuple(_ctx, acc, %{subject_id: "*", subject_relation: ""} = tuple) do
    {:ok, Subjects.allow_all(acc, tuple.subject_type)}
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

  @doc false
  @spec resource_ids(map(), term(), map(), String.t(), String.t(), map(), keyword()) ::
          {:ok, MapSet.t()} | {:error, Error.t()}
  def resource_ids(schema, reader, revision, resource_type, permission, subject, opts) do
    ctx = context(schema, reader, revision, opts, false)
    resources(ctx, resource_type, {:ref, permission}, subject)
  end

  defp resources(ctx, resource_type, expr, subject) do
    with :ok <- before_expand(ctx),
         {:ok, definition} <- fetch_definition(ctx, resource_type) do
      resource_expr(ctx, definition, resource_type, expr, subject)
    end
  end

  defp resource_expr(ctx, definition, resource_type, {:ref, name}, subject) do
    cond do
      Map.has_key?(definition.relations, name) ->
        resources_for_relation(ctx, resource_type, name, subject)

      Map.has_key?(definition.permissions, name) ->
        resources(ctx, resource_type, Map.fetch!(definition.permissions, name), subject)

      true ->
        {:error,
         Error.new(:unknown_relation, "unknown relation or permission #{resource_type}##{name}")}
    end
  end

  defp resource_expr(ctx, _definition, resource_type, {:union, left, right}, subject) do
    with {:ok, left_ids} <- resources(ctx, resource_type, left, subject),
         {:ok, right_ids} <- resources(ctx, resource_type, right, subject) do
      capped_ids(ctx, MapSet.union(left_ids, right_ids))
    end
  end

  defp resource_expr(ctx, _definition, resource_type, {:intersection, left, right}, subject) do
    with {:ok, left_ids} <- resources(ctx, resource_type, left, subject),
         {:ok, right_ids} <- resources(ctx, resource_type, right, subject) do
      capped_ids(ctx, MapSet.intersection(left_ids, right_ids))
    end
  end

  defp resource_expr(ctx, _definition, resource_type, {:exclusion, left, right}, subject) do
    with {:ok, left_ids} <- resources(ctx, resource_type, left, subject),
         {:ok, right_ids} <- resources(ctx, resource_type, right, subject) do
      capped_ids(ctx, MapSet.difference(left_ids, right_ids))
    end
  end

  defp resource_expr(ctx, _definition, resource_type, {:arrow, left, right}, subject) do
    ctx = deeper(ctx)
    expr = remaining_expr(left, right)

    ctx
    |> tuples(%{resource_type: resource_type, relation: relation_name(left)})
    |> Enum.reduce_while({:ok, MapSet.new()}, fn tuple, {:ok, acc} ->
      consider_arrow(ctx, acc, tuple, expr, subject)
    end)
  end

  defp remaining_expr(left, right) when is_binary(left), do: right
  defp remaining_expr({:arrow, _left, inner}, right), do: {:arrow, relation_name(inner), right}

  defp consider_arrow(ctx, acc, tuple, expr, subject) do
    if arrow_target(tuple) == [] do
      {:cont, {:ok, acc}}
    else
      case resources_allowed?(ctx, tuple, expr, subject) do
        {:ok, true} -> keep(capped_ids(ctx, MapSet.put(acc, tuple.resource_id)))
        {:ok, false} -> {:cont, {:ok, acc}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end
  end

  defp resources_allowed?(ctx, tuple, right, subject) do
    case expression(ctx, tuple.subject_type, tuple.subject_id, right, subject) do
      {:ok, :allowed, _children} -> {:ok, true}
      {:ok, :denied, _children} -> {:ok, false}
      {:error, error} -> {:error, error}
    end
  end

  defp resources_for_relation(ctx, resource_type, name, subject) do
    ctx
    |> tuples(%{resource_type: resource_type, relation: name})
    |> Enum.reduce_while({:ok, MapSet.new()}, fn tuple, {:ok, acc} ->
      consider_resource(deeper(ctx), acc, tuple, subject)
    end)
  end

  defp resource_match(_ctx, tuple, subject) do
    cond do
      concrete_subject?(tuple, subject) -> {:ok, true}
      wildcard_subject?(tuple, subject) -> {:ok, true}
      tuple.subject_relation != "" -> {:error, :walk}
      true -> {:ok, false}
    end
  end

  defp concrete_subject?(tuple, subject) do
    tuple.subject_relation == "" and tuple.subject_type == subject.type and
      tuple.subject_id == subject.id
  end

  defp wildcard_subject?(tuple, subject) do
    tuple.subject_relation == "" and tuple.subject_id == "*" and
      tuple.subject_type == subject.type and subject.relation == ""
  end

  defp consider_resource(ctx, acc, tuple, subject) do
    case resource_match(ctx, tuple, subject) do
      {:ok, true} -> keep(capped_ids(ctx, MapSet.put(acc, tuple.resource_id)))
      {:ok, false} -> {:cont, {:ok, acc}}
      {:error, :walk} -> walk_resource(ctx, acc, tuple, subject)
    end
  end

  defp walk_resource(ctx, acc, tuple, subject) do
    case eval(ctx, tuple.subject_type, tuple.subject_id, tuple.subject_relation, subject) do
      {:ok, :allowed, _trace} -> keep(capped_ids(ctx, MapSet.put(acc, tuple.resource_id)))
      {:ok, :denied, _trace} -> {:cont, {:ok, acc}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp relation_name(name) when is_binary(name), do: name
  defp relation_name({:ref, name}), do: name
  defp relation_name({:arrow, left, _right}), do: relation_name(left)

  defp capped_ids(ctx, %MapSet{} = ids) do
    case lookup_guard(MapSet.size(ids), ctx.max_lookup) do
      :ok -> {:ok, ids}
      {:error, error} -> {:error, error}
    end
  end

  defp keep({:ok, value}), do: {:cont, {:ok, value}}
  defp keep({:error, error}), do: {:halt, {:error, error}}
end
