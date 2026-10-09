defmodule Licet.NewEnemyTest do
  @moduledoc """
  The New Enemy problem from the Zanzibar paper, as SpiceDB tests it in
  `e2e/newenemy`: a check at a revision must never see a grant without the
  exclusion written before it.

  Writes commit for real, outside the SQL sandbox, so `{:exact, token}` reads
  the snapshot Postgres recorded for each write.
  """

  use Licet.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox

  @direct """
  definition user {}
  definition resource {
    relation direct: user
    relation excluded: user
    permission allowed = direct - excluded
  }
  """

  @through_lists """
  definition user {}
  definition blocklist {
    relation user: user
  }
  definition allowlist {
    relation user: user
  }
  definition resource {
    relation direct: allowlist
    relation excluded: blocklist
    permission allowed = direct->user - excluded->user
  }
  """

  test "an exclusion written before a grant holds at both tokens" do
    outside(@direct, fn name ->
      {:ok, excluded} = Licet.write(name, [{:create, "resource:thegoods#excluded@user:1"}])
      {:ok, granted} = Licet.write(name, [{:create, "resource:thegoods#direct@user:1"}])

      assert allowed(name, {:exact, excluded}) == {:ok, :denied}
      assert allowed(name, {:exact, granted}) == {:ok, :denied}
      assert allowed(name, {:at_least, granted}) == {:ok, :denied}

      {:ok, lifted} = Licet.write(name, [{:delete, "resource:thegoods#excluded@user:1"}])

      assert allowed(name, {:exact, excluded}) == {:ok, :denied}
      assert allowed(name, {:exact, granted}) == {:ok, :denied}
      assert allowed(name, {:exact, lifted}) == {:ok, :allowed}
      assert allowed(name, :full) == {:ok, :allowed}
    end)
  end

  test "the same ordering holds when both sides go through arrows, as in SpiceDB's e2e schema" do
    outside(@through_lists, fn name ->
      {:ok, _lists} =
        Licet.write(name, [
          {:create, "resource:thegoods#direct@allowlist:1"},
          {:create, "resource:thegoods#excluded@blocklist:1"}
        ])

      {:ok, excluded} = Licet.write(name, [{:create, "blocklist:1#user@user:1"}])
      {:ok, granted} = Licet.write(name, [{:create, "allowlist:1#user@user:1"}])

      assert allowed(name, {:exact, excluded}) == {:ok, :denied}
      assert allowed(name, {:exact, granted}) == {:ok, :denied}

      {:ok, lifted} = Licet.write(name, [{:delete, "blocklist:1#user@user:1"}])

      assert allowed(name, {:exact, granted}) == {:ok, :denied}
      assert allowed(name, {:exact, lifted}) == {:ok, :allowed}
    end)
  end

  defp allowed(name, consistency) do
    Licet.check(name, "resource:thegoods", "allowed", "user:1", consistency: consistency)
  end

  defp outside(schema, fun) do
    prefix = "ne" <> Integer.to_string(System.os_time(:native))

    name =
      Module.concat(Licet.NewEnemy, "I" <> Integer.to_string(System.unique_integer([:positive])))

    Sandbox.unboxed_run(Licet.TestRepo, fn ->
      Licet.Testing.migrate!(Licet.TestRepo, prefix)

      start_supervised!(
        {Licet,
         name: name,
         repo: Licet.TestRepo,
         prefix: prefix,
         schema: {:string, schema},
         gc_interval: false}
      )

      fun.(name)
    end)
  end
end
