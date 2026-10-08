defmodule Licet.Page do
  @moduledoc false

  @spec slice([term()], String.t() | nil, pos_integer()) ::
          {:ok, [term()], String.t() | nil} | {:error, Licet.Error.t()}
  def slice(items, cursor, limit) when is_list(items) and is_integer(limit) and limit > 0 do
    sorted = Enum.sort(items)

    case drop_cursor(sorted, cursor) do
      {:ok, rest} ->
        page = Enum.take(rest, limit)
        next = if length(rest) > limit, do: encode(List.last(page)), else: nil
        {:ok, page, next}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec encode(term()) :: String.t()
  def encode(value) do
    "v1." <> Base.url_encode64(Jason.encode!(value), padding: false)
  end

  defp drop_cursor(items, nil), do: {:ok, items}

  defp drop_cursor(items, cursor) do
    case decode(cursor) do
      {:ok, value} -> {:ok, Enum.drop_while(items, &(not after_cursor?(&1, value)))}
      :error -> {:error, Licet.Error.new(:invalid_filter, "cursor is invalid")}
    end
  end

  defp decode("v1." <> encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, value} <- Jason.decode(json) do
      {:ok, normalize(value)}
    else
      _ -> :error
    end
  end

  defp decode(_other), do: :error

  defp normalize(value) when is_binary(value), do: value

  defp normalize([type, id, relation])
       when is_binary(type) and is_binary(id) and is_binary(relation), do: {type, id, relation}

  defp normalize(value), do: value

  defp after_cursor?(item, cursor), do: item > cursor
end
