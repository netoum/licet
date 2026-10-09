# Phoenix integration

This guide shows where Licet fits in a Phoenix application: granting access when a record is created, checking access in contexts, filtering lists, and common plug and LiveView patterns. The runnable JSON blog in [`examples/blog`](https://github.com/netoum/licet/tree/main/examples/blog) implements create, fetch, and list with this schema. The plug, LiveView, and sharing sections below are patterns that go beyond that example.

```zed
definition user {}

definition post {
  relation owner: user
  relation viewer: user
  permission view = owner + viewer
}
```

## Starting Licet

Start Licet after the repo and before the endpoint, so it's ready before the first request arrives:

```elixir
children = [
  MyApp.Repo,
  {Licet,
   name: MyApp.Licet,
   repo: MyApp.Repo,
   schema: {:file, Application.app_dir(:my_app, "priv/licet/schema.zed")}},
  {Phoenix.PubSub, name: MyApp.PubSub},
  MyAppWeb.Endpoint
]
```

Use `Application.app_dir/2` for the schema path so it resolves inside a release.

## Granting access when a record is created

Write the owner relationship in the same transaction as the insert. If either fails, both roll back, so there's never a post without an owner or an owner of a post that doesn't exist:

```elixir
defmodule MyApp.Posts do
  alias MyApp.{Post, Repo}

  def create_post(author_id, attrs) when is_binary(author_id) do
    changeset = Post.changeset(%Post{}, Map.put(attrs, :author_id, author_id))

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:post, changeset)
    |> Ecto.Multi.run(:grant, fn _repo, %{post: post} ->
      Licet.write(MyApp.Licet, [{:create, "post:#{post.id}#owner@user:#{author_id}"}])
    end)
    |> Repo.transaction()
  end
end
```

`Ecto.Multi.run/3` is used here because the relationship needs the id of the inserted post. When the relationships are known up front, `Licet.Multi.write(multi, MyApp.Licet, :grant, updates)` is shorter.

The result includes the write's token in `:grant`. Keep it if the next request must see the new access immediately, as described below.

## Checking in a context

Put the authorization check next to the data access it protects, so every caller gets it. At the context boundary, treat both denial and a Licet error (for example a timeout) as `:not_found`, so a failed check never reveals that a record exists and never opens access by accident:

```elixir
def fetch_post(user_id, id) when is_binary(user_id) do
  case Licet.check(MyApp.Licet, "post:#{id}", "view", "user:#{user_id}") do
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
```

## Checking in a plug

A function plug can protect a group of routes. This pattern is not in the blog example; use it when you have authenticated `current_user` assigns:

```elixir
defmodule MyAppWeb.Authorize do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, type: type, permission: permission, param: param) do
    user = conn.assigns.current_user
    resource = "#{type}:#{conn.path_params[param]}"

    case Licet.check(MyApp.Licet, resource, permission, "user:#{user.id}") do
      {:ok, :allowed} ->
        conn

      _denied_or_error ->
        conn
        |> put_status(:not_found)
        |> Phoenix.Controller.put_view(MyAppWeb.ErrorHTML)
        |> Phoenix.Controller.render(:"404")
        |> halt()
    end
  end
end
```

```elixir
plug MyAppWeb.Authorize, [type: "post", permission: "view", param: "id"] when action in [:show]
```

## Checking in a LiveView

An `on_mount` hook checks access when a LiveView mounts, both on the first HTTP request and when the socket connects:

```elixir
defmodule MyAppWeb.PostAuth do
  import Phoenix.LiveView

  def on_mount(permission, %{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    case Licet.check(MyApp.Licet, "post:#{id}", permission, "user:#{user.id}") do
      {:ok, :allowed} -> {:cont, socket}
      _denied_or_error -> {:halt, socket |> put_flash(:error, "Not found") |> redirect(to: "/")}
    end
  end
end
```

```elixir
live_session :posts, on_mount: [{MyAppWeb.UserAuth, :ensure_authenticated}] do
  live "/posts/:id", PostLive.Show
end

defmodule MyAppWeb.PostLive.Show do
  use MyAppWeb, :live_view

  on_mount {MyAppWeb.PostAuth, "view"}
end
```

`on_mount` runs only when the LiveView mounts. Check again inside `handle_event/3` before any action that changes data, because access may have been revoked while the page was open.

## Filtering lists

When the posts already live in your tables, page them in SQL and filter the page with `Licet.check_bulk/3`. That is what [`examples/blog`](https://github.com/netoum/licet/tree/main/examples/blog) does:

```elixir
def list_posts(user_id, opts \\ []) when is_binary(user_id) do
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

  case Licet.check_bulk(MyApp.Licet, checks) do
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
```

A page can be shorter than `limit` when some rows are denied. If `check_bulk` itself fails (for example the snapshot can't be resolved), return an empty list so the page fails closed. Prefer this over `Licet.lookup_resources/5` when SQL already names the candidates: a lookup computes the full result before paging and fails with `:lookup_too_large` past `max_lookup`. Use `lookup_resources/5` when the candidate set is the permission graph itself; see [Operations](operations.md).

## Seeing your own writes

By default a check reads a shared snapshot that is refreshed every few seconds. After a user creates a post and is redirected to it, the next request might not see the new owner relationship yet. Two ways to handle it:

* Pass the token along and check with `consistency: {:at_least, token}`. It's a string, so it can travel in the session, the flash, or a query parameter.
* Check with `consistency: :full` on the pages that follow a write, such as the redirect after create.

Inside the same transaction as the write, checks always see it. See [Consistency](consistency.md) for details.

## Sharing

A sharing dialog needs both directions. `Licet.lookup_subjects/5` lists who can view a post, and a write adds a viewer:

```elixir
{:ok, viewers, _cursor} = Licet.lookup_subjects(MyApp.Licet, "post:#{id}", "view", "user")

{:ok, _token} = Licet.write(MyApp.Licet, [{:touch, "post:#{id}#viewer@user:#{friend_id}"}])
```

`:touch` creates the relationship, or keeps an existing one and updates its expiration, so sharing twice isn't an error. `:create` fails with `:already_exists` instead.
