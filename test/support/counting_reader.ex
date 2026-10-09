defmodule Licet.CountingReader do
  @moduledoc false
  defstruct [:memory, :test]

  defimpl Licet.Reader do
    def list(reader, filter) do
      send(reader.test, :listed)
      Licet.Reader.list(reader.memory, filter)
    end
  end
end
