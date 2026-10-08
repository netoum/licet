defprotocol Licet.Reader do
  @moduledoc """
  Reads relationship tuples for the check engine.

  `Licet.Reader.Memory` serves schema validation. `Licet.Reader.Postgres`
  serves a running Licet instance.
  """

  @spec list(t(), map()) :: [Licet.Relationship.t()]
  def list(reader, filter)
end
