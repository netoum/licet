# Changelog

## 1.0.0 - 2026-10-08

First release.

* Parse and evaluate a SpiceDB `.zed` subset: definitions, relations, permissions, unions, intersections, exclusions, arrows, wildcards, usersets, and expiration.
* Store tuples, schemas, and snapshots in Postgres 15+ with xid8 visibility, read-your-writes inside a transaction, and Ecto sandbox support.
* Check, bulk check, lookup resources, lookup subjects, and explain, with depth and timeout limits.
* Consistency tokens (`:minimize_latency`, `:at_least`, `:exact`, `:full`), an ETS cache, and in-flight deduplication.
* Reject schema changes that would strand living tuples.
* Garbage-collect tombstones and expired tuples under an advisory lock.
* `mix licet.gen.migration`, `mix licet.validate`, `Licet.Multi`, and `Licet.Testing`.
