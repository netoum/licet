defmodule Licet.SlowReader do
  @moduledoc false
  defstruct [:memory, :test, :slow]

  defimpl Licet.Reader do
    def list(reader, filter) do
      send(reader.test, {:listed, filter.resource_id})
      if filter.resource_id == reader.slow, do: Process.sleep(200)
      Licet.Reader.list(reader.memory, filter)
    end
  end
end
