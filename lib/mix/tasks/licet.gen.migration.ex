defmodule Mix.Tasks.Licet.Gen.Migration do
  @moduledoc """
  Generates an Ecto migration that installs Licet tables.

      mix licet.gen.migration --prefix licet --path priv/repo/migrations/install_licet.exs
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
