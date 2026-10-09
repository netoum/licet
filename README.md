# Licet

Relationship-based authorization for Elixir, stored in your Postgres database.

Licet evaluates a [SpiceDB](https://authzed.com/docs/spicedb) `.zed` subset in your application and keeps the tuples next to your other data. A write inside `Repo.transaction/2` is visible to a check in that same transaction, and it disappears if the transaction rolls back.

## Install

```elixir
def deps do
  [
    {:licet, "~> 1.0"}
  ]
end
```

Licet requires Elixir 1.17 or newer and Postgres 15 or newer.

## Start

Generate a migration, then start an instance beside your repo:

```elixir
children = [
  MyApp.Repo,
  {Licet,
   name: MyApp.Licet,
   repo: MyApp.Repo,
   prefix: "licet",
   schema: {:file, "priv/licet/schema.zed"}}
]
```

```shell
mix licet.gen.migration --prefix licet
```

```zed
definition user {}

definition document {
  relation owner: user
  relation viewer: user | user:*
  permission view = owner + viewer
}
```

```elixir
{:ok, _token} = Licet.write(MyApp.Licet, [{:create, "document:1#owner@user:ada"}])
{:ok, :allowed} = Licet.check(MyApp.Licet, "document:1", "view", "user:ada")
```

## What v1 includes

- Definitions, relations, permissions, `+`, `&`, `-`, `->`, `.any()`, `.all()`, `nil`, wildcards, and `team#member`
- `use expiration` and `with expiration`
- `check`, `check_bulk`, `lookup_resources`, `lookup_subjects`, and `explain`
- Zed tokens and four consistency modes: `:minimize_latency`, `{:at_least, token}`, `{:exact, token}`, `:full`
- An ETS cache, in-flight deduplication, and optional parallel arrow checks
- Schema diffing that rejects changes that would strand living tuples
- Garbage collection behind a Postgres advisory lock
- `Licet.Multi`, `Licet.Testing`, and `mix licet.validate`

Caveats, `self`, Watch, and a networked service are intentionally out of v1. See the [upgrade guide](guides/upgrade.md).

## Documentation

- [Getting started](guides/getting-started.md)
- [Schema language](guides/zed.md)
- [Consistency](guides/consistency.md)
- [Transactions](guides/transactions.md)
- [Design](guides/design.md)
- [Security](guides/security.md)

## Development

```shell
mix test
mix credo --strict
mix docs --warnings-as-errors
```

Tests expect Postgres on `127.0.0.1:54329` by default (`PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`). They log at `:warning`; set `config :logger, level: :debug` in `config/test.exs` to see every query.

`examples/playground` is a local playground for SpiceDB validation files, checked by Licet as you type (`mix setup && mix phx.server`).

## License

Apache-2.0. Copyright Netoum.
