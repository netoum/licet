# Licet

[![Hex.pm](https://img.shields.io/hexpm/v/licet.svg)](https://hex.pm/packages/licet)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/licet)
[![CI](https://github.com/netoum/licet/actions/workflows/ci.yml/badge.svg)](https://github.com/netoum/licet/actions/workflows/ci.yml)

Licet evaluates [SpiceDB](https://authzed.com/docs/spicedb) permission schemas (`.zed` files) inside your Elixir application, with relationships stored in your own Postgres database. There is no SpiceDB server to run.

*Licet* is Latin for "it is permitted".

Licet answers questions like "can Ada edit this document?" from relationships you store: Ada owns the folder, the folder contains the document, owners of a folder can edit what's in it. This is relationship-based access control (ReBAC), as described in Google's [Zanzibar paper](https://research.google/pubs/zanzibar-googles-consistent-global-authorization-system/). Because the schema is plain SpiceDB, you can start embedded and move to a SpiceDB cluster later without rewriting it.

## Why Licet

* **SpiceDB's language and behavior.** Schemas are SpiceDB `.zed` files. Licet's answers are tested against SpiceDB's own test suite, and compared with a live SpiceDB in CI on every push.
* **No extra service.** Relationships live in your Postgres database, in tables created by an ordinary Ecto migration. There is nothing else to deploy or monitor.
* **Transactional.** A write joins your `Repo.transaction/2`. A check in the same transaction already sees it, and a rollback discards it together with the rest of your data. Granting the owner of a new record can never fail independently of creating the record.
* **Consistent when it matters.** Every write returns a token. Pass it to a later check to guarantee that check sees the write, even on another node. Use the cached default for everything else.

## Installation

Add Licet to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:licet, "~> 0.1"}
  ]
end
```

Licet needs Elixir 1.17 or newer and Postgres 15 or newer.

## A two-minute example

Describe your permissions in `priv/licet/schema.zed`:

```zed
definition user {}

definition team {
  relation member: user
}

definition document {
  relation owner: user
  relation viewer: user | team#member
  permission edit = owner
  permission view = owner + viewer
}
```

Generate the migration that creates Licet's tables, then run it:

```shell
mix licet.gen.migration
mix ecto.migrate
```

Start Licet in your supervision tree, after your repo:

```elixir
children = [
  MyApp.Repo,
  {Licet,
   name: MyApp.Licet,
   repo: MyApp.Repo,
   schema: {:file, Application.app_dir(:my_app, "priv/licet/schema.zed")}}
]
```

Write relationships and check permissions:

```elixir
{:ok, token} =
  Licet.write(MyApp.Licet, [
    {:create, "document:roadmap#owner@user:ada"},
    {:create, "team:eng#member@user:bob"},
    {:create, "document:roadmap#viewer@team:eng#member"}
  ])

opts = [consistency: {:at_least, token}]

Licet.check(MyApp.Licet, "document:roadmap", "view", "user:bob", opts)
#=> {:ok, :allowed}

Licet.check(MyApp.Licet, "document:roadmap", "edit", "user:bob", opts)
#=> {:ok, :denied}

Licet.lookup_resources(MyApp.Licet, "document", "view", "user:bob", opts)
#=> {:ok, ["roadmap"], nil}
```

By default a check reads a snapshot that is refreshed every few seconds and shared through a cache. Passing the token from a write guarantees the check sees that write. [Consistency](guides/consistency.md) explains the trade-off.

[Getting started](guides/getting-started.md) walks through the same steps in more detail.

## Features

* The SpiceDB schema language: union, intersection, exclusion, arrows (including `.any()` and `.all()`), wildcards such as "every user", nested groups through usersets, and relationships that expire.
* Checks one at a time or in bulk, with a cache per snapshot and deduplication of identical checks in flight.
* Lookups in both directions: every document a user can view, or every user who can view a document. Results are paginated.
* `explain/5`, which shows why a check was allowed or denied.
* Four consistency modes, from the cached default to always-fresh.
* Schema changes are checked against stored relationships, so a deploy can't silently revoke access.
* Test helpers for the Ecto sandbox, and `mix licet.validate` for SpiceDB validation files.
* Telemetry events for checks, lookups, writes, and the cache.

## Coming from SpiceDB?

Your `.zed` schema and your validation files run unchanged, unless they use caveats or `self`. [Migrating to or from SpiceDB](guides/migrating.md) covers moving relationships in either direction, and [Limitations](guides/limitations.md) lists what Licet leaves out, such as caveats and the Watch API.

## When to use something else

* **Several services need the same permissions**, or you need caveats or a stream of changes: run [SpiceDB](https://authzed.com/docs/spicedb) and call it with the [`authzed`](https://hex.pm/packages/authzed) client. Licet's [limitations](guides/limitations.md) page lists what it leaves out.
* **Your rules are simple roles**, such as "admins can do everything": a policy module with [Bodyguard](https://hex.pm/packages/bodyguard) or [LetMe](https://hex.pm/packages/let_me) is less to learn.

## Examples

* [`examples/blog`](https://github.com/netoum/licet/tree/main/examples/blog) — a small Phoenix JSON API with Postgres: create a post and its owner in one transaction, then fetch and list with `Licet.check/5` and `Licet.check_bulk/3`.
* [`examples/playground`](https://github.com/netoum/licet/tree/main/examples/playground) — a local SpiceDB validation-file editor. It needs no database: assertions and expected relations run through `Licet.Validate`, and you can explain one check as you type.

## Documentation

* [Getting started](guides/getting-started.md)
* [Concepts](guides/concepts.md)
* [Modeling permissions](guides/modeling.md) and the [schema language](guides/zed.md)
* [Phoenix integration](guides/phoenix.md)
* [Consistency](guides/consistency.md) and [transactions](guides/transactions.md)
* [Testing](guides/testing.md)
* [Operations](guides/operations.md), [telemetry](guides/telemetry.md), and [security](guides/security.md)
* [Migrating to or from SpiceDB](guides/migrating.md)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to run the test suite, including the comparison against a live SpiceDB.

## License

Licet is released under the Apache License 2.0. Copyright Netoum.

SpiceDB is a trademark of AuthZed. Licet is an independent project and is not affiliated with AuthZed.
