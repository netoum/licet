defmodule Licet.Error do
  @moduledoc """
  An expected failure from a Licet call.

  Functions return `{:error, %Licet.Error{}}` instead of raising. Match on the
  `reason` atom; it is stable. `message` is a human-readable explanation for
  developers and logs, and may change between versions. `details` carries
  structured context, such as the `:line` and `:column` of a schema error.

      case Licet.check(MyApp.Licet, "document:1", "view", "user:ada") do
        {:ok, :allowed} -> :ok
        {:ok, :denied} -> {:error, :forbidden}
        {:error, %Licet.Error{reason: :timeout}} -> {:error, :unavailable}
        {:error, %Licet.Error{} = error} -> raise error
      end

  `Licet.start_link/1` and invalid options raise the error instead, since they
  indicate a bug in configuration rather than a runtime condition.

  ## Reasons

  ### Input

  | Reason | Meaning | What to do |
  | --- | --- | --- |
  | `:invalid_relationship` | Malformed object or relationship text, a wildcard resource, or a subject or expiration the relation doesn't allow. | Fix the input. The message names the problem. |
  | `:unknown_type` | The object type isn't defined in the schema. | Check the spelling, or add the definition. |
  | `:unknown_relation` | The relation or permission isn't defined on that type. | Check the spelling, or add it to the schema. |
  | `:invalid_filter` | An empty or malformed filter, subject type, preconditions list, or cursor. | Fix the argument. |
  | `:invalid_schema` | The schema doesn't parse or is inconsistent. `details` has `:line` and `:column`. | Fix the schema at that position. |
  | `:invalid_validation_file` | A validation file is malformed. | Fix the YAML. |
  | `:invalid_config` | Invalid instance options or an unknown consistency mode. | Fix the option. |

  ### Writes

  | Reason | Meaning | What to do |
  | --- | --- | --- |
  | `:already_exists` | A `:create` or import of a relationship that is already stored. | Use `:touch` if repeating the write is fine. |
  | `:precondition_failed` | A write precondition didn't hold. Nothing was written. | Re-read and decide again. |
  | `:too_many_updates` | More updates than `max_updates` (or `max_import`). | Split the batch. |
  | `:too_many_preconditions` | More preconditions than `max_preconditions`. | Use fewer, broader filters. |
  | `:unsafe_schema_change` | The new schema would strand stored relationships. | Delete those relationships first. See [Operations](operations.md). |

  ### Queries

  | Reason | Meaning | What to do |
  | --- | --- | --- |
  | `:timeout` | The check or lookup took longer than the instance `timeout`. | Treat as a denial. Simplify the schema or raise the limit. |
  | `:depth_exceeded` | Evaluation went deeper than `max_depth` hops. | Look for a very deep hierarchy, or raise the limit. |
  | `:cycle` | Evaluation revisited the same object and permission. | Check the data for a loop, such as a folder that is its own parent. |
  | `:lookup_too_large` | A lookup found more results than `max_lookup`. | Narrow the query, or check objects individually. |
  ### Consistency

  | Reason | Meaning | What to do |
  | --- | --- | --- |
  | `:token_invalid` | The token is malformed or wasn't issued by Licet. | Drop it and use the default consistency. |
  | `:token_not_committed` | The token's transaction rolled back, or is still open on another connection. | Retry after the transaction commits, or drop the token. |
  | `:snapshot_expired` | The token is older than `gc_window`, so its exact snapshot is gone. | Use `{:at_least, token}` or the default instead. |

  ### Setup

  | Reason | Meaning | What to do |
  | --- | --- | --- |
  | `:not_started` | No instance with that name is running. | Start it in your supervision tree. |
  | `:not_migrated` | Licet's tables don't exist in the prefix. | Run `mix licet.gen.migration` and migrate. |
  """

  defexception [:reason, :message, :details]

  @type reason ::
          :already_exists
          | :cycle
          | :depth_exceeded
          | :invalid_config
          | :invalid_filter
          | :invalid_relationship
          | :invalid_schema
          | :invalid_validation_file
          | :lookup_too_large
          | :not_migrated
          | :not_started
          | :precondition_failed
          | :snapshot_expired
          | :timeout
          | :token_invalid
          | :token_not_committed
          | :too_many_preconditions
          | :too_many_updates
          | :unknown_relation
          | :unknown_type
          | :unsafe_schema_change

  @type t :: %__MODULE__{reason: reason(), message: String.t(), details: map()}

  @doc """
  Builds an error.

  `details` defaults to an empty map.
  """
  @spec new(reason(), String.t(), map()) :: t()
  def new(reason, message, details \\ %{})
      when is_atom(reason) and is_binary(message) and is_map(details) do
    %__MODULE__{reason: reason, message: message, details: details}
  end

  @impl true
  def message(%__MODULE__{message: message}), do: message
end
