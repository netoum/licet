# Licet blog example

A small Phoenix JSON API that stores posts in Postgres and their permissions in Licet. Creating a post writes the owner relationship in the same transaction. Fetch and list filter with `Licet.check/5` and `Licet.check_bulk/3`.

## Setup

Postgres on `127.0.0.1:54329` (same defaults as the Licet test suite), then:

```sh
mix deps.get
mix ecto.create
mix ecto.migrate
mix phx.server
```

The API listens on [localhost:4000](http://localhost:4000).

## Try it

Create a post for Ada:

```sh
curl -s -X POST http://127.0.0.1:4000/posts \
  -H 'content-type: application/json' \
  -d '{"title":"Hello","author_id":"ada"}'
```

Fetch and list as Ada (allowed) or Bob (empty / 404):

```sh
curl -s 'http://127.0.0.1:4000/posts/1?user_id=ada'
curl -s 'http://127.0.0.1:4000/posts?user_id=ada'
curl -s 'http://127.0.0.1:4000/posts/1?user_id=bob'
curl -s 'http://127.0.0.1:4000/posts?user_id=bob'
```

`mix test` creates `blog_test` and runs the context tests. See the [Phoenix integration](../../guides/phoenix.md) guide for the patterns this example implements.

The example depends on the library in this repository with `{:licet, path: "../.."}`. If you copy it out, use `{:licet, "~> 0.1"}` instead.
