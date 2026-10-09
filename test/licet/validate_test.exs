defmodule Licet.ValidateTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Runner

  doctest Licet.Validate

  setup do
    owner = Sandbox.start_owner!(Licet.TestRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  test "runs a conformance file and the mix task" do
    path = "test/conformance/document.yaml"
    assert :ok = Licet.Validate.run_file(path)
    assert :ok = Mix.Task.rerun("licet.validate", [path])

    assert {:error, [%{expected: :allowed}]} =
             Licet.Validate.run(
               "schema: |\n  definition user {}\nassertions:\n  assertTrue:\n    - user:1#view@user:1\n"
             )
  end

  test "generates a migration" do
    path = "tmp/install_licet.exs"
    File.rm(path)

    Mix.Task.rerun("licet.gen.migration", [
      "--prefix",
      "licet",
      "--path",
      path,
      "--module",
      "Licet.Test.Install"
    ])

    assert File.read!(path) =~ "Licet.Migration.up"
    File.rm(path)
  end

  test "differential harness skips without spice" do
    unless System.get_env("LICET_SPICEDB") == "1" do
      assert Licet.Differential.maybe() == :skipped
    end
  end

  @tag :spicedb
  test "agrees with spicedb on generated cases" do
    assert :ok = Licet.Differential.maybe()
  end

  test "migration up and down run inside ecto" do
    defmodule UpDown do
      use Ecto.Migration

      def up, do: Licet.Migration.up(prefix: "licet_cover_mig")
      def down, do: Licet.Migration.down(prefix: "licet_cover_mig")
    end

    Sandbox.unboxed_run(Licet.TestRepo, fn ->
      Runner.run(Licet.TestRepo, [], 1, UpDown, :forward, :up, :up, log: false)

      assert %{num_rows: 1} =
               Licet.TestRepo.query!(
                 "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'licet_cover_mig'"
               )

      Runner.run(Licet.TestRepo, [], 1, UpDown, :forward, :down, :down, log: false)

      defmodule Defaults do
        use Ecto.Migration

        def up, do: Licet.Migration.up()
        def down, do: Licet.Migration.down()
      end

      Runner.run(Licet.TestRepo, [], 2, Defaults, :forward, :up, :up, log: false)

      Runner.run(Licet.TestRepo, [], 2, Defaults, :forward, :down, :down, log: false)
    end)
  end
end
