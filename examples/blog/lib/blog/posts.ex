defmodule Blog.Posts do
  @moduledoc """
  Creates a post and its owner relationship in one transaction.
  """

  def create_post(author_id, attrs) when is_binary(author_id) and is_map(attrs) do
    changeset = Blog.Post.changeset(%Blog.Post{}, Map.put(attrs, :author_id, author_id))

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:post, changeset)
    |> Ecto.Multi.run(:grant, fn _repo, %{post: post} ->
      Licet.write(Blog.Licet, [{:create, "post:#{post.id}#owner@user:#{author_id}"}])
    end)
    |> Blog.Repo.transaction()
  end
end
