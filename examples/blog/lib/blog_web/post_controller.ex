defmodule BlogWeb.PostController do
  use Phoenix.Controller, formats: [:json]

  def create(conn, %{"title" => title, "author_id" => author_id}) do
    case Blog.Posts.create_post(author_id, %{title: title}) do
      {:ok, %{post: post}} ->
        json(conn, %{id: post.id, title: post.title})

      {:error, _reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "could not create post"})
    end
  end
end
