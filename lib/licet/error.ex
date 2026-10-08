defmodule Licet.Error do
  @moduledoc """
  An expected failure from a Licet call.

  Functions return `{:error, %Licet.Error{}}`. The `reason` field is a stable
  atom. `message` is safe to show to developers. `details` carries structured
  context such as schema line and column.
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
          | :lookup_too_large
          | :not_migrated
          | :not_started
          | :precondition_failed
          | :snapshot_expired
          | :timeout
          | :token_invalid
          | :token_not_committed
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
