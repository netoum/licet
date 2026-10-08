# Operations

## Limits

| Option | Default | Meaning |
| --- | --- | --- |
| `max_updates` | 1000 | Tuples in one `write/3` |
| `max_import` | 10000 | Tuples in one `import/3` |
| `max_preconditions` | 1000 | Preconditions on a write |
| `max_depth` | 50 | Arrow and userset hops |
| `max_lookup` | 10000 | Subjects or resources in one lookup |
| `timeout` | 5000 | Milliseconds for one check or lookup |
| `gc_window` | 86400 | Seconds of history to keep |
| `gc_interval` | 300000 | Milliseconds between collections, or `false` |
| `gc_batch` | 1000 | Rows deleted per batch |
| `quantization` | 5000 | Milliseconds between revision refreshes |

`import/3` only creates tuples. It uses `max_import`, not `max_updates`.

## Lookups

```elixir
{:ok, ids, cursor} = Licet.lookup_resources(MyApp.Licet, "document", "view", "user:ada", limit: 100)
{:ok, more, nil} = Licet.lookup_resources(MyApp.Licet, "document", "view", "user:ada", cursor: cursor, limit: 100)

{:ok, subjects, _cursor} = Licet.lookup_subjects(MyApp.Licet, "document:1", "view")
```

Subjects are rendered as `user:ada` or `team:eng#member`. A result bigger than `max_lookup` returns `:lookup_too_large`.

## Explain

```elixir
{:ok, :allowed, trace} = Licet.explain(MyApp.Licet, "document:1", "view", "user:ada")
```

Explain walks the same plan as check and returns the trace. It does not run arrow targets in parallel.

## Schema changes

`Licet.write_schema/2` rejects a new schema when:

* a removed definition or relation still has a living tuple
* `use expiration` is removed while a living tuple has `expires_at`
* a relation no longer allows a subject type that still has living tuples

Ship an expansion first, delete the tuples that depend on the old shape, then narrow the schema.

## Garbage collection

The `GC` process runs on `gc_interval` unless that option is `false`. One node holds `pg_try_advisory_lock`. The others observe `:locked` and skip the pass. Call `Licet.GC.collect/1` to run a pass immediately.

History inside `gc_window` is kept, so an `:exact` token from that window still resolves.
