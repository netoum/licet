defprotocol Licet.Reader do
  # Reads relationship tuples for the check engine.
  #
  # `Licet.Reader.Memory` serves schema validation. `Licet.Reader.Postgres`
  # serves a running Licet instance.
  @moduledoc false

  @spec list(t(), map()) :: [Licet.Relationship.t()]
  def list(reader, filter)
end
