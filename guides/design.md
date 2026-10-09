# Design

Licet stores relationship tuples in Postgres and evaluates them in Elixir. The storage shape follows SpiceDB's Postgres datastore: each write is a transaction id, and reads use a snapshot so a check can be repeated later and see the same tuples.

## Tables

Each instance uses one schema prefix (default `licet`). Three tables live there.

`relationships` holds one row per tuple. `subject_relation` is `''` when the subject is a concrete object or a wildcard, never NULL. `deleted_xid` is NULL while the row is alive. A partial unique index on the six identity columns `WHERE deleted_xid IS NULL` stops two living copies of the same tuple.

`transactions` records the `xid8` of a Licet write, the `pg_snapshot` taken for that write, and the database clock time. Tokens point at this row. They do not embed the snapshot as the source of truth.

`schemas` stores the exact schema text, its sha256, and the xid that created it. A new schema tombstones the previous row in the same write.

## Visibility

A row is visible at a revision when all of these hold:

- it was created by this transaction, or `pg_visible_in_snapshot(created_xid, snapshot)`
- it is not deleted, or the delete is not this transaction and is not visible in the snapshot
- `expires_at` is NULL or later than the revision time

`pg_current_snapshot()` does not treat the current transaction's xid as visible. Licet therefore passes that xid as its own xid and matches `created_xid` by equality. That is how a check inside a transaction sees the write that has not committed yet.

The write path calls `pg_current_xact_id()` before `pg_current_snapshot()`, then inserts the `transactions` row, then applies preconditions and tuple changes. A second write in the same database transaction reuses the existing xid row instead of inserting another one. Postgres aborts a transaction after a unique violation, so the reuse is a lookup, not a rescued error.

The read path never calls `pg_current_xact_id()`. It uses `pg_current_xact_id_if_assigned/0`, which is empty when the session has not written. An empty own-xid means "this snapshot only".

## Tokens and consistency

A token is `v1.` plus URL-safe base64 JSON: version, xid, snapshot text, and timestamp. Decode checks the shapes (`xid` is 1–20 digits, snapshot matches `xmin:xmax:xip`) and does not decode Erlang terms.

`:exact` loads the stored snapshot for that xid after `pg_xact_status` says the transaction committed. The same connection may read an in-progress xid. An aborted xid is rejected. A committed xid with no `transactions` row is outside the cleanup window.

`:minimize_latency` uses the `Revision` process, which refreshes on the quantization interval (default 5 seconds) and allows the cache. `{:at_least, token}` uses that revision when the token xid is visible in it, otherwise a fresh snapshot. `:full` always takes a fresh snapshot and does not cache.

Inside an open transaction, including a shared Ecto sandbox transaction that already has an assigned xid, every mode except `:exact` reads `pg_current_snapshot()` on the calling connection and skips the cache. After commit, the xid is no longer assigned, so checks go back to the revision process.

## Cache

The cache is a public ETS table whose name is distinct from the `Cache` process (`Instance.CacheTable` versus `Instance.Cache`). Keys include the whole revision: the snapshot, the own xid, and the time used for expiration. The snapshot alone is not enough. A transaction's recorded snapshot does not list its own xid, so it can have the same text as an autocommit snapshot taken just before it. The token for that transaction must still see its own writes. Errors, in-transaction checks, and `:full` are not stored. Concurrent misses for one key register in a `Registry` and the waiters reuse the first result.

## Evaluation

The schema compiler turns permissions into unions, intersections, exclusions, `nil`, and arrows. The semantics follow SpiceDB's dispatcher:

- An arrow (`->` or `.any()`) walks the tupleset relation and checks the right-hand name on each subject object. Wildcard rows are skipped. A row's subject relation is ignored, so `document:1#parent@folder:1#viewer` leads to `folder:1`, as in SpiceDB's `checkdispatchset`.
- `.all()` requires every subject object to grant. With no subject objects it grants nothing.
- A subject type that does not define the right-hand name contributes nothing. The schema is rejected only when no subject type of the tupleset defines it.
- A userset subject is a member of itself: `document:1#viewer` has `viewer` on `document:1` at every step, in checks and in lookups.
- A check walks userset rows even when the subject is itself a userset, so `group:a#member` can reach `group:b#member` through `group:b#member@group:a#member`.

Depth counts hops. The default limit is 50. A timeout is a monotonic deadline checked before each step.

Direct cycles such as `view = view` are rejected at schema compile time. Recursion through data, such as `view = parent->view`, is allowed. Reaching the same object and name twice on one path returns a `:cycle` error. The stack is per path, so a diamond is not a cycle.

With a running instance, the branches of an arrow or a userset walk run in parallel under the instance's `Task.Supervisor`. The first `:allowed` or error settles the answer and raises a shared cancel flag. Siblings check the flag before their next step and stop, the same way SpiceDB cancels a branch through its context. A sibling is killed only when the deadline passes. Killing it while it holds a checked-out connection would make Postgrex drop that connection.

## Why Postgres only

SpiceDB supports several datastores because it is a standalone service. Licet is a library inside an Elixir application that already runs Postgres through Ecto. Postgres gives Licet everything SpiceDB's Postgres datastore uses: `xid8` transaction ids, `pg_snapshot` visibility, and transactional writes on the application's own connection. That last part lets a permission write join the application's `Ecto.Multi` and be read back before commit, which a separate datastore cannot offer. One datastore also means one visibility rule to test, and the conformance corpus runs against it directly. The `xid8` and `pg_snapshot` functions exist since Postgres 13. Licet supports Postgres 15 and newer, the versions CI runs.

## Sandbox

`Ecto.Adapters.SQL.Sandbox` with `start_owner!(shared: true)` keeps the transaction on the owner process. `in_transaction?/1` on the test process is therefore false. Licet notices a sandbox pool and, when `pg_current_xact_id_if_assigned()` returns an xid, uses that connection's snapshot. A checkout with `sandbox: false` has no assigned xid after commit, so those tests exercise tokens, the cache, and garbage collection for real.

## Cleanup

Garbage collection takes a session advisory lock (`pg_try_advisory_lock` on a bigint). The horizon is the oldest snapshot xmin still inside the window (default 24 hours), or the current xmin when nothing is that old. Tombstones with `deleted_xid` below the horizon, rows expired before the window, and old transaction rows except the newest are deleted in batches of 1,000. Exact tokens inside the window stay valid because expired rows are kept until the window passes.
