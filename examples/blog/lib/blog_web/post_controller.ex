defmodule BlogWeb.PostController do
  use Phoenix.Controller, formats: [:json]

  def create(conn, %{"title" => title, "author_id" => author_id}) do
    case Blog.Posts.create_post(author_id, %{title: title}) do
      {:ok, %{post: post}} ->
        json(conn, post_json(post))

      {:error, _reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "could not create post"})
    end
  end

  def show(conn, %{"id" => id, "user_id" => user_id}) do
    case Blog.Posts.fetch_post(user_id, id) do
      {:ok, post} ->
        json(conn, post_json(post))

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not found"})
    end
  end

  def index(conn, %{"user_id" => user_id} = params) do
    opts =
      []
      |> maybe_put(:limit, parse_int(params["limit"]))
      |> maybe_put(:after_id, parse_int(params["after_id"]))

    case Blog.Posts.list_posts(user_id, opts) do
      {:ok, posts} ->
        json(conn, Enum.map(posts, &post_json/1))
    end
  end

  defp post_json(post), do: %{id: post.id, title: post.title}

  defp parse_int(nil), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp parse_int(value) when is_integer(value), do: value

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
