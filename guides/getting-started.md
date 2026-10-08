# Getting started

Add Licet to your supervision tree after the repo it should use:

```elixir
children = [
  MyApp.Repo,
  {Licet,
   name: MyApp.Licet,
   repo: MyApp.Repo,
   prefix: "licet",
   schema: {:string, File.read!("priv/licet/schema.zed")}}
]
```

`name` is the instance name you pass to every call. `prefix` is the Postgres schema that holds the three Licet tables. It must match `^[a-z_][a-z0-9_]{0,62}$`.

Generate and run the migration before the instance starts:

```shell
mix licet.gen.migration --prefix licet --path priv/repo/migrations/install_licet.exs
```

The instance refuses to start until `relationships` exists.

## A check

```elixir
{:ok, token} =
  Licet.write(MyApp.Licet, [
    {:create, "document:1#owner@user:ada"},
    {:touch, "document:1#viewer@user:bob"}
  ])

{:ok, :allowed} = Licet.check(MyApp.Licet, "document:1", "view", "user:ada")
{:ok, :denied} = Licet.check(MyApp.Licet, "document:1", "view", "user:cara")
```

`token` is a consistency token for this write. See [Consistency](consistency.md).

## In a transaction

```elixir
MyApp.Repo.transaction(fn ->
  MyApp.Repo.insert!(changeset)
  {:ok, _token} = Licet.write(MyApp.Licet, [{:create, "document:#{id}#owner@user:#{user_id}"}])
  :ok
end)
```

A check on the same connection, before the transaction commits, sees that tuple. If the transaction rolls back, the token cannot be used.
