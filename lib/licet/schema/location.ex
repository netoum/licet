defmodule Licet.Schema.Location do
  @moduledoc false

  @spec line_col(binary(), non_neg_integer()) :: {pos_integer(), pos_integer()}
  def line_col(source, offset) when is_binary(source) and is_integer(offset) do
    offset = offset |> max(0) |> min(byte_size(source))
    head = binary_part(source, 0, offset)
    lines = String.split(head, "\n")
    {length(lines), String.length(List.last(lines)) + 1}
  end
end
