defmodule Blog.Post do
  use Ecto.Schema

  schema "posts" do
    field :title, :string
    field :author_id, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(post, attrs) do
    post
    |> Ecto.Changeset.cast(attrs, [:title, :author_id])
    |> Ecto.Changeset.validate_required([:title, :author_id])
  end
end
