defmodule Mix.Tasks.Licet.Gen.Migration do
  @moduledoc """
  Generates the Ecto migration that creates Licet's tables.

      $ mix licet.gen.migration
      $ mix ecto.migrate

  The migration calls `Licet.Migration.up/1` and `Licet.Migration.down/1`.

  ## Options

    * `--prefix` - the Postgres schema for the tables. Defaults to `licet`, which
      is also the default `:prefix` of an instance.
    * `--path` - where to write the file. Defaults to
      `priv/repo/migrations/<timestamp>_install_licet.exs`.
    * `--module` - the migration module name. Defaults to a name derived from
      the file name.
  """

  use Mix.Task

  @shortdoc "Generates an Ecto migration for Licet"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args, strict: [prefix: :string, path: :string, module: :string])

    prefix = opts[:prefix] || "licet"
    path = opts[:path] || default_path()
    module = opts[:module] || module_name(path)
    source = Licet.Migration.migration_source(prefix: prefix, module: module)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    Mix.shell().info("created #{path}")
  end

  defp default_path do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    "priv/repo/migrations/#{stamp}_install_licet.exs"
  end

  defp module_name(path) do
    path
    |> Path.basename(".exs")
    |> String.trim_leading("0123456789_")
    |> Macro.camelize()
    |> then(&"Licet.Repo.Migrations.#{&1}")
  end
end
