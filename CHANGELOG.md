# Changelog

## Unreleased

* Accept `.any()`, `.all()`, and `nil`.
* Bind `+` tighter than `&`, and `&` tighter than `-`, as SpiceDB does. Before, `&` and `-` had the same precedence, so `a - b & c` parsed as `(a - b) & c`.
* A userset subject is a member of itself: `document:1#viewer@document:1#viewer` is allowed.
* Accept the `#...` subject suffix as no relation.
* Arrows follow a tupleset row's subject object and ignore its subject relation, as SpiceDB does. Before, rows with a subject relation were skipped.
* An arrow's right-hand name only needs to exist on one subject type. Types without it contribute nothing.
* Checks walk usersets even when the subject is a userset.
* Fix a stale cache hit under `{:exact, token}`. The check cache was keyed on the snapshot text alone. A write's recorded snapshot can match an autocommit snapshot taken just before the write, so a token could return a result cached before its own write. Keys now carry the whole revision: snapshot, own xid, and time. Found by the New Enemy test.
* Parallel branches stop through a shared cancel flag instead of being killed mid-query, so a short-circuited check no longer makes Postgrex drop a connection.
* `Licet.Validate` reads the `validation` section, reports SpiceDB's messages, and regenerates it with `expected_relations/1`. Malformed validation files return `:invalid_validation_file`.
* The schema parser reports `unexpected character X` and names caveats and `use self` as unsupported.
* **Breaking:** `lookup_subjects/5` takes a subject type, as SpiceDB's LookupSubjects does: `Licet.lookup_subjects(name, "document:1", "view", "user")`, or `"team#member"` for a userset type. Results are maps such as `%{subject: "user:*", excluded: ["user:dan"]}`. Before, `lookup_subjects/4` returned strings of every type, dropped a wildcard's exclusions, and hid concrete subjects behind a wildcard.
* `lookup_subjects` follows SpiceDB's subject sets: concrete subjects are listed next to a wildcard, removing a subject from a wildcard records it as excluded, and a userset counts as a member of itself.
* Run SpiceDB's consistency corpus on the in-memory reader and on Postgres.
* Compare every corpus file with a live SpiceDB in CI: every check, LookupResources, and LookupSubjects over the file's objects and subjects.
* Add `examples/playground`, a local Phoenix app that edits a validation file and checks it with `Licet.Validate` as you type.

## 1.0.0 - 2026-10-08

First release.

* Parse and evaluate a SpiceDB `.zed` subset: definitions, relations, permissions, unions, intersections, exclusions, arrows, wildcards, usersets, and expiration.
* Store tuples, schemas, and snapshots in Postgres 15+ with xid8 visibility, read-your-writes inside a transaction, and Ecto sandbox support.
* Check, bulk check, lookup resources, lookup subjects, and explain, with depth and timeout limits.
* Consistency tokens (`:minimize_latency`, `:at_least`, `:exact`, `:full`), an ETS cache, and in-flight deduplication.
* Reject schema changes that would strand living tuples.
* Garbage-collect tombstones and expired tuples under an advisory lock.
* `mix licet.gen.migration`, `mix licet.validate`, `Licet.Multi`, and `Licet.Testing`.
