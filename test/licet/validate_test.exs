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

    assert_raise Mix.Error, ~r/already exists/, fn ->
      Mix.Task.rerun("licet.gen.migration", ["--path", path])
    end

    File.rm(path)

    assert_raise Mix.Error, ~r/--pathh/, fn ->
      Mix.Task.rerun("licet.gen.migration", ["--pathh", path])
    end

    assert_raise Mix.Error, ~r/unexpected argument/, fn ->
      Mix.Task.rerun("licet.gen.migration", ["extra"])
    end

    assert_raise Mix.Error, ~r/not a valid Postgres schema/, fn ->
      Mix.Task.rerun("licet.gen.migration", ["--prefix", "Bad-Name", "--path", path])
    end

    refute File.exists?(path)

    Mix.Task.rerun("licet.gen.migration", ["--path", path])
    assert File.read!(path) =~ "defmodule Licet.Repo.Migrations.InstallLicet"
    File.rm(path)
  end

  test "the validate task prints help and schema error positions" do
    help = ExUnit.CaptureIO.capture_io(fn -> Mix.Task.rerun("licet.validate", ["--help"]) end)
    assert help =~ "FILE:LINE:COLUMN"

    path = "tmp/broken_schema.yaml"
    File.write!(path, "schema: |\n  definition user {\n    relation\n  }\n")

    assert_raise Mix.Error, ~r/^tmp\/broken_schema\.yaml:\d+:\d+: /, fn ->
      Mix.Task.rerun("licet.validate", [path])
    end

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
