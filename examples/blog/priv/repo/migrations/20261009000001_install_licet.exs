defmodule Blog.Repo.Migrations.InstallLicet do
  use Ecto.Migration

  def up, do: Licet.Migration.up(prefix: "licet")
  def down, do: Licet.Migration.down(prefix: "licet")
end
