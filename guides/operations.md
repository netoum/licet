# Operations

This guide covers running Licet in production: configuration, schema changes, lookups at scale, debugging a check, garbage collection, and running on several nodes.

## Configuration

All options are given in the child spec. Only `name` and `repo` are required:

| Option | Default | Meaning |
| --- | --- | --- |
| `name` | required | Instance name passed to every function |
| `repo` | required | The `Ecto.Repo` that holds Licet's tables |
| `prefix` | `"licet"` | Postgres schema that holds the tables |
| `schema` | `nil` | `{:file, path}` or `{:string, source}` to load at startup; `nil` keeps the stored schema |
| `quantization` | `5_000` | Milliseconds between refreshes of the shared snapshot |
| `timeout` | `5_000` | Milliseconds allowed for one check or lookup |
| `max_depth` | `50` | Arrow and userset hops in one check |
| `max_lookup` | `10_000` | Results computed by one lookup |
| `max_updates` | `1_000` | Updates in one `Licet.write/3` |
| `max_import` | `10_000` | Relationships in one `Licet.import/3` |
| `max_preconditions` | `1_000` | Preconditions on one write |
| `gc_interval` | `300_000` | Milliseconds between garbage collections, or `false` to disable |
| `gc_window` | `86_400` | Seconds of history to keep |
| `gc_batch` | `1_000` | Rows deleted per garbage collection batch |

The `Licet` module documentation describes each option in detail.

## Schema changes

The schema can change in two ways:

* Deploy a new schema file. When an instance starts with a `schema` that differs from the stored one, it stores the new version.
* Call `Licet.write_schema/3` at runtime.

Either way, Licet first compares the new schema with the relationships that are stored, and refuses with `:unsafe_schema_change` when the change would leave some of them meaningless:

* a removed definition or relation still has relationships
* `use expiration` is removed while relationships still carry an expiry
* a relation no longer accepts a subject type that still has relationships

When an instance refuses its configured schema, it doesn't start, so a bad deploy fails fast instead of silently revoking access.

To narrow a schema safely, use two deploys:

1. Stop writing the relationships you're about to make invalid, and delete the existing ones with `Licet.delete/3`.
2. Deploy the narrower schema.

Widening a schema, such as adding a relation, a permission, or a subject type, is always accepted.

## Lookups at scale

Lookups return pages, sorted by id:

```elixir
{:ok, ids, cursor} =
  Licet.lookup_resources(MyApp.Licet, "document", "view", "user:ada", limit: 100)

{:ok, more_ids, nil} =
  Licet.lookup_resources(MyApp.Licet, "document", "view", "user:ada", cursor: cursor, limit: 100)
```

A `nil` cursor means there are no more pages. The default page size is 100.

Each lookup computes the full result before returning a page, and fails with `:lookup_too_large` when it exceeds `max_lookup`. For permissions that can reach many objects, such as anything granted through a wildcard, prefer a check per object, or filter in SQL first and check the remaining candidates with `Licet.check_bulk/3`.

`Licet.lookup_subjects/5` takes a subject type: `"user"` for users, or `"team#member"` for team memberships. Each result names a subject and the ids it excludes:

```elixir
Licet.lookup_subjects(MyApp.Licet, "document:1", "view", "user")
#=> {:ok, [%{subject: "user:*", excluded: ["user:dan"]}, %{subject: "user:tom", excluded: []}], nil}
```

Only a wildcard excludes anything. `user:*` with `user:dan` excluded means every user except Dan. Concrete subjects are listed even when a wildcard also covers them, and a userset counts as a member of itself, so `team:eng#member` is listed when the lookup reaches it.

## Debugging a check

`Licet.explain/5` returns the answer and a trace of the permissions it evaluated:

```elixir
{:ok, :allowed, trace} = Licet.explain(MyApp.Licet, "document:1", "view", "user:ada")

trace
#=> %{
#=>   resource: "document:1",
#=>   permission: "view",
#=>   result: :allowed,
#=>   children: [%{resource: "folder:plans", permission: "view", result: :allowed, children: [...]}]
#=> }
```

Each node names a resource and permission, its result, and the nodes evaluated beneath it. Explain follows the same path as a check but runs sequentially and never uses the cache, so it's slower. Use it to debug, not to serve requests.

## Garbage collection

Deletes and expired relationships aren't removed immediately: Licet keeps history so that tokens can be read at their exact snapshot. A garbage collector deletes history older than `gc_window` every `gc_interval`, in batches of `gc_batch` rows.

On several nodes, only one collects at a time. Each pass takes a Postgres advisory lock, and the others skip that pass.

Set `gc_interval: false` to disable automatic collection, for example in tests or to run it from a scheduled job. `Licet.GC.collect/1` runs a pass immediately.

## Several nodes

Each node runs its own instance against the same database, with the same options. The shared snapshot and the cache are per node, so two nodes can briefly disagree under `:minimize_latency`, by at most one `quantization` interval. Pass tokens between requests when a user must see their own writes on whichever node serves them. See [Consistency](consistency.md).

## Monitoring

Licet emits telemetry events for checks, lookups, writes, and cache hits and misses. See [Telemetry](telemetry.md) for the events and an example of metrics.

## Table layout

Licet uses three tables in its prefix: `relationships`, `transactions`, and `schemas`. Treat them as private and change them only through Licet. [Design](internals/design.md) describes them for the curious.
