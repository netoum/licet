defmodule Blog.Repo.Migrations.CreatePosts do
  use Ecto.Migration

  def change do
    create table(:posts) do
      add :title, :string, null: false
      add :author_id, :string, null: false
      timestamps(type: :utc_datetime)
    end
  end
end
