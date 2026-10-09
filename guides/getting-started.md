# Getting started

This guide adds Licet to an existing Phoenix or Ecto application. It assumes you have a working `Ecto.Repo` backed by Postgres 15 or newer. By the end, you'll have a schema, the database tables, a running instance, and your first checks.

If the vocabulary is new to you, read [Concepts](concepts.md) first.

## Install

Add Licet to your dependencies in `mix.exs`. It isn't published to Hex yet, so depend on the repository:

```elixir
def deps do
  [
    {:licet, github: "netoum/licet"}
  ]
end
```

Then fetch it:

```shell
mix deps.get
```

## Write a schema

The schema describes your object types, the relations between them, and how permissions are computed. Create `priv/licet/schema.zed`:

```zed
definition user {}

definition document {
  relation owner: user
  relation viewer: user | user:*
  permission edit = owner
  permission view = owner + viewer
}
```

A document has owners and viewers. Owners can edit. Owners and viewers can view. `user:*` lets a viewer relationship name every user, which is how a document is made public.

Check the file before going further:

```shell
mix run -e 'IO.inspect(Licet.Schema.parse(File.read!("priv/licet/schema.zed")))'
```

A mistake is reported with its line and column. [Schema language](zed.md) describes everything a schema can contain.

## Create the tables

Licet stores relationships, schema versions, and snapshots in three tables, inside a Postgres schema of their own (`licet` by default). Generate a migration for them and run it:

```shell
mix licet.gen.migration
mix ecto.migrate
```

The generator writes `priv/repo/migrations/<timestamp>_install_licet.exs`. Pass `--prefix` to use another Postgres schema name and `--path` to choose the file. The prefix must be a lowercase identifier: letters, digits, and underscores, starting with a letter or underscore.

## Start an instance

Add Licet to your supervision tree after the repo:

```elixir
children = [
  MyApp.Repo,
  {Licet,
   name: MyApp.Licet,
   repo: MyApp.Repo,
   schema: {:file, Application.app_dir(:my_app, "priv/licet/schema.zed")}},
  MyAppWeb.Endpoint
]
```

`name` identifies the instance. You pass it as the first argument of every Licet function. `repo` is the repo that holds the tables. `schema` is the schema to load at startup; when it differs from the stored one, Licet stores the new version, after checking that the change doesn't strand existing relationships.

The instance refuses to start if the migration hasn't run. All options are listed in the `Licet` module documentation.

## Write relationships

A relationship is a fact such as "Ada owns document 1", written `document:1#owner@user:ada`. Write a batch with `Licet.write/3`:

```elixir
{:ok, token} =
  Licet.write(MyApp.Licet, [
    {:create, "document:1#owner@user:ada"},
    {:create, "document:1#viewer@user:bob"}
  ])
```

All updates in a call succeed or fail together. The result is a consistency token for this write.

## Check permissions

```elixir
Licet.check(MyApp.Licet, "document:1", "edit", "user:ada", consistency: {:at_least, token})
#=> {:ok, :allowed}

Licet.check(MyApp.Licet, "document:1", "edit", "user:bob", consistency: {:at_least, token})
#=> {:ok, :denied}

Licet.check(MyApp.Licet, "document:1", "view", "user:bob", consistency: {:at_least, token})
#=> {:ok, :allowed}
```

The `consistency` option guarantees these checks see the write that produced `token`. Without it, a check reads a shared snapshot that is refreshed every 5 seconds by default, which is faster and cached but can briefly miss a recent write. [Consistency](consistency.md) explains how to choose.

Make the document public with a wildcard:

```elixir
{:ok, token} = Licet.write(MyApp.Licet, [{:create, "document:1#viewer@user:*"}])

Licet.check(MyApp.Licet, "document:1", "view", "user:cara", consistency: {:at_least, token})
#=> {:ok, :allowed}
```

## Write in a transaction

Licet writes join an open `Repo.transaction/2`. Create a record and its owner together, so neither exists without the other:

```elixir
MyApp.Repo.transaction(fn ->
  document = MyApp.Repo.insert!(changeset)
  {:ok, _token} = Licet.write(MyApp.Licet, [{:create, "document:#{document.id}#owner@user:#{user.id}"}])
  document
end)
```

A check inside the transaction already sees the new relationship. If the transaction rolls back, the relationship is gone too. See [Transactions](transactions.md).

## Next steps

* [Modeling permissions](modeling.md) covers groups, hierarchies, and other common patterns.
* [Phoenix integration](phoenix.md) shows checks in contexts, plugs, and LiveViews.
* [Testing](testing.md) explains how to use Licet with the Ecto SQL sandbox.
