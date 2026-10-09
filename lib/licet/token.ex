defmodule Licet.Token do
  # Opaque consistency token returned by writes.
  #
  # A token names the Postgres snapshot at which that write is visible.
  # Tokens are versioned text. They are not a secret, but they are not a
  # stable primary key either: garbage collection rejects exact reads of
  # snapshots older than the configured window.
  @moduledoc false

  @type t :: String.t()

  @type decoded :: %{xid: String.t(), snapshot: String.t(), at: DateTime.t()}

  @max_bytes 8_192

  @doc """
  Encodes a snapshot into a token.
  """
  @spec encode(decoded()) :: t()
  def encode(%{xid: xid, snapshot: snapshot, at: %DateTime{} = at})
      when is_binary(xid) and is_binary(snapshot) do
    payload =
      Jason.encode!(%{
        "v" => 1,
        "xid" => xid,
        "snapshot" => snapshot,
        "at" => DateTime.to_iso8601(at)
      })

    "v1." <> Base.url_encode64(payload, padding: false)
  end

  @doc """
  Decodes a token.

  Returns `:token_invalid` when the text is not a Licet token.
  """
  @spec decode(t()) :: {:ok, decoded()} | {:error, :token_invalid}
  def decode("v1." <> encoded) when byte_size(encoded) <= @max_bytes do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, map} <- Jason.decode(json),
         {:ok, decoded} <- cast(map) do
      {:ok, decoded}
    else
      _ -> {:error, :token_invalid}
    end
  end

  def decode(_other), do: {:error, :token_invalid}

  defp cast(%{"v" => 1, "xid" => xid, "snapshot" => snapshot, "at" => at})
       when is_binary(xid) and is_binary(snapshot) and is_binary(at) do
    with true <- snapshot?(snapshot),
         true <- xid?(xid),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(at) do
      {:ok, %{xid: xid, snapshot: snapshot, at: DateTime.truncate(datetime, :microsecond)}}
    else
      _ -> :error
    end
  end

  defp cast(_map), do: :error

  defp snapshot?(value) do
    Regex.match?(~r/^[0-9]+:[0-9]+:[0-9,]{0,4096}$/, value)
  end

  defp xid?(value), do: Regex.match?(~r/^[0-9]{1,20}$/, value)
end
