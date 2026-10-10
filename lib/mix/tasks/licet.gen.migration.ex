defmodule Mix.Tasks.Licet.Gen.Migration do
  @moduledoc """
  Generates the Ecto migration that creates Licet's tables.

      $ mix licet.gen.migration
      $ mix ecto.migrate

  The migration calls `Licet.Migration.up/1` and `Licet.Migration.down/1`.

  ## Options

    * `--prefix` - the Postgres schema for the tables. Defaults to `licet`, which
      is also the default `:prefix` of an instance. It must match
      `^[a-z_][a-z0-9_]{0,62}$`.
    * `--path` - where to write the file. Defaults to
      `priv/repo/migrations/<timestamp>_install_licet.exs`. The task refuses to
      overwrite an existing file.
    * `--module` - the migration module name. Defaults to
      `<App>.Repo.Migrations.InstallLicet`, derived from your application name
      and the file name.
  """

  use Mix.Task

  @shortdoc "Generates an Ecto migration for Licet"

  @switches [prefix: :string, path: :string, module: :string]
  @prefix ~r/^[a-z_][a-z0-9_]{0,62}$/

  @impl Mix.Task
  def run(args) do
    opts = parse!(args)
    prefix = opts[:prefix] || "licet"

    unless Regex.match?(@prefix, prefix) do
      Mix.raise("--prefix #{inspect(prefix)} is not a valid Postgres schema name")
    end

    path = opts[:path] || default_path()
    module = opts[:module] || module_name(path)

    if File.exists?(path) do
      Mix.raise("#{path} already exists")
    end

    source = Licet.Migration.migration_source(prefix: prefix, module: module)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    Mix.shell().info("created #{path}")
  end

  defp parse!(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        opts

      {_opts, _argv, [{switch, _value} | _]} ->
        Mix.raise("unknown or invalid option #{switch}. See `mix help licet.gen.migration`")

      {_opts, [arg | _], []} ->
        Mix.raise("unexpected argument #{inspect(arg)}. See `mix help licet.gen.migration`")
    end
  end

  defp default_path do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    "priv/repo/migrations/#{stamp}_install_licet.exs"
  end

  defp module_name(path) do
    name =
      path
      |> Path.basename(".exs")
      |> String.trim_leading("0123456789_")
      |> Macro.camelize()

    app = Mix.Project.config() |> Keyword.fetch!(:app) |> Atom.to_string() |> Macro.camelize()
    "#{app}.Repo.Migrations.#{name}"
  end
end
