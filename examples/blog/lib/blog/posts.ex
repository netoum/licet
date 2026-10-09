defmodule Blog.Posts do
  @moduledoc """
  Creates a post and its owner relationship in one transaction, and reads
  posts the caller may view.

  `list_posts/2` pages the `posts` table in SQL, then filters that page with
  `Licet.check_bulk/3`. A page can be shorter than `limit` when some rows are
  denied; it does not scan further to fill it. Prefer that over
  `Licet.lookup_resources/5` when the candidate set already lives in your
  tables: a lookup computes the full result before paging and fails with
  `:lookup_too_large` past `max_lookup`. See the operations guide.
  """

  import Ecto.Query

  alias Blog.Post
  alias Blog.Repo

  def create_post(author_id, attrs) when is_binary(author_id) and is_map(attrs) do
    changeset = Post.changeset(%Post{}, Map.put(attrs, :author_id, author_id))

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:post, changeset)
    |> Ecto.Multi.run(:grant, fn _repo, %{post: post} ->
      Licet.write(Blog.Licet, [{:create, "post:#{post.id}#owner@user:#{author_id}"}])
    end)
    |> Repo.transaction()
  end

  def fetch_post(user_id, id) when is_binary(user_id) do
    case Licet.check(Blog.Licet, "post:#{id}", "view", "user:#{user_id}") do
      {:ok, :allowed} ->
        case Repo.get(Post, id) do
          nil -> {:error, :not_found}
          post -> {:ok, post}
        end

      {:ok, :denied} ->
        {:error, :not_found}

      {:error, _error} ->
        {:error, :not_found}
    end
  end

  def list_posts(user_id, opts \\ []) when is_binary(user_id) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 20)
    after_id = Keyword.get(opts, :after_id)

    query =
      from(p in Post,
        order_by: [desc: p.id],
        limit: ^limit
      )

    query =
      if after_id do
        from(p in query, where: p.id < ^after_id)
      else
        query
      end

    candidates = Repo.all(query)

    checks =
      Enum.map(candidates, fn post ->
        %{resource: "post:#{post.id}", permission: "view", subject: "user:#{user_id}"}
      end)

    case Licet.check_bulk(Blog.Licet, checks) do
      {:ok, results} ->
        posts =
          candidates
          |> Enum.zip(results)
          |> Enum.filter(fn {_post, result} -> result == {:ok, :allowed} end)
          |> Enum.map(fn {post, _result} -> post end)

        {:ok, posts}

      {:error, _error} ->
        {:ok, []}
    end
  end
end
