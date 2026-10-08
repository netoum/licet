defmodule Licet.FakeRepo do
  @moduledoc false

  def config, do: [pool: DBConnection.ConnectionPool]
end
