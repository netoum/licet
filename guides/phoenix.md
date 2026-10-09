# Phoenix integration

This guide shows where Licet fits in a Phoenix application: granting access when a record is created, checking access in contexts, controllers, and LiveViews, and filtering lists. The code follows the blog app in [`examples/blog`](https://github.com/netoum/licet/tree/main/examples/blog), which uses this schema:

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

Write the owner relationship in the same transaction as the insert. If either fails, both roll back, so there's never a post without an owner or an owner of a post that doesn't exist. `Licet.Multi.write/5` adds the write as a step of an `Ecto.Multi`:

```elixir
defmodule MyApp.Posts do
  alias MyApp.{Post, Repo}

  def create_post(%{id: user_id}, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:post, Post.changeset(%Post{}, attrs))
    |> Ecto.Multi.run(:grant, fn _repo, %{post: post} ->
      Licet.write(MyApp.Licet, [{:create, "post:#{post.id}#owner@user:#{user_id}"}])
    end)
    |> Repo.transaction()
  end
end
```

`Ecto.Multi.run/3` is used here because the relationship needs the id of the inserted post. When the relationships are known up front, `Licet.Multi.write(multi, MyApp.Licet, :grant, updates)` is shorter.

The result includes the write's token in `:grant`. Keep it if the next request must see the new access immediately, as described below.

## Checking in a context

Put the authorization check next to the data access it protects, so every caller gets it:

```elixir
def fetch_post(%{id: user_id}, id) do
  case Licet.check(MyApp.Licet, "post:#{id}", "view", "user:#{user_id}") do
    {:ok, :allowed} -> {:ok, Repo.get!(Post, id)}
    {:ok, :denied} -> {:error, :not_found}
    {:error, %Licet.Error{} = error} -> {:error, error}
  end
end
```

Returning `:not_found` on denial avoids telling a user that a record they can't see exists. Treat `{:error, _}` as a denial too: when Licet can't answer, for example because the check timed out, the safe default is no access.

## Checking in a plug

A function plug can protect a group of routes. This one checks a permission on the resource named by a path parameter:

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

To show only the posts a user can view, ask Licet for the ids, then load them:

```elixir
def list_posts(%{id: user_id}) do
  {:ok, ids, _cursor} =
    Licet.lookup_resources(MyApp.Licet, "post", "view", "user:#{user_id}", limit: 100)

  ids = Enum.map(ids, &String.to_integer/1)
  Repo.all(from p in Post, where: p.id in ^ids, order_by: [desc: p.inserted_at])
end
```

Licet returns ids as strings, so convert them when your primary keys are integers. Results come in pages of `:limit` ids, sorted by id. Pass the returned cursor as `:cursor` to get the next page.

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
