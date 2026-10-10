# Changelog

All notable changes to Licet are recorded here. Licet follows [Semantic Versioning](https://semver.org).

## Unreleased

## 0.1.0 (2026-10-10)

The first public version.

### Schema language

* Parse SpiceDB's `.zed` schema language: definitions, relations, and permissions built from union (`+`), intersection (`&`), exclusion (`-`), and arrows (`->`).
* Arrow functions `.any()` and `.all()`, the empty set `nil`, wildcards such as `user:*`, and userset subjects such as `team#member`.
* Relationships that expire, with `use expiration` and `with expiration`.
* Operator precedence and arrow resolution match SpiceDB.
* Errors report a line and column. Caveats and `self` are rejected with a clear message.

### Storage and consistency

* Relationships, schema versions, and snapshots live in three tables in your own Postgres 15+ database, under a prefix you choose.
* Writes join the caller's `Repo.transaction/2`. A check in the same transaction sees the uncommitted write, and a rollback discards it. A failed write is undone back to a savepoint and returned as an error, so the caller, or `Ecto.Multi`, decides what happens to the transaction.
* Every write returns a consistency token. Checks accept four consistency modes: `:minimize_latency`, `{:at_least, token}`, `{:exact, token}`, and `:full`.
* Schema changes that would strand stored relationships are rejected. A schema stored with `write_schema/3` reaches every node within one `quantization` interval.
* Garbage collection removes old history behind a Postgres advisory lock, so only one node collects at a time.

### Queries

* `check/5` and `check_bulk/3`, with a shared cache per snapshot and deduplication of identical checks in flight. A check reads one level of the graph per query, and `check_bulk/3` answers checks that share a resource type, permission, and subject together.
* `lookup_resources/5` and `lookup_subjects/5`, paginated with cursors. `lookup_resources/5` walks back from the subject, so its cost follows the size of the answer rather than the number of resources. `lookup_subjects/5` reports which subjects a wildcard excludes.
* `explain/5` returns the trace of a check.
* Depth, time, and result-size limits on every query.

### Tooling

* `Licet.Multi` adds a write to an `Ecto.Multi`.
* `Licet.Testing` creates tables per test prefix and shares the Ecto sandbox with processes the test starts.
* `mix licet.gen.migration` generates the install migration.
* `mix licet.validate` runs a SpiceDB validation file, the YAML that the SpiceDB playground exports, including its expected relations.
* Telemetry events for checks, lookups, writes, and the cache.
