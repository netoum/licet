defmodule Licet.DataCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Licet.DataCase
    end
  end

  setup do
    owner = Sandbox.start_owner!(Licet.TestRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  def start_licet!(schema, opts \\ []) do
    prefix = "t" <> Integer.to_string(System.unique_integer([:positive]))
    Licet.Testing.migrate!(Licet.TestRepo, prefix)
    name = instance_name()

    start_supervised!(
      {Licet,
       [
         name: name,
         repo: Licet.TestRepo,
         prefix: prefix,
         schema: {:string, schema},
         gc_interval: false
       ] ++ opts}
    )

    name
  end

  defp instance_name do
    Module.concat(Licet.Instance, "I" <> Integer.to_string(System.unique_integer([:positive])))
  end
end
