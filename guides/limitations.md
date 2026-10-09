# Limitations

Licet implements most of SpiceDB's schema language and query API inside your application. This page lists what it doesn't do, so you can decide early whether it fits.

## Stability

Licet is at version 0.0.x. Until 0.1, any release may change the public API, the table layout, or the token format. Each change is described in the [changelog](../CHANGELOG.md). Pin an exact version or commit in `mix.exs` and read the changelog before you upgrade.

## Not supported

**Caveats.** SpiceDB's `caveat` blocks attach CEL expressions to relationships, for example "only during business hours". Licet rejects a schema that declares one. Put conditions like these in your application code, next to the call to `Licet.check/5`.

**`self`.** The `use self` directive and the `self` keyword are rejected.

**Watch.** There is no stream of relationship changes. Code that needs to react to permission changes should broadcast them itself, for example with `Phoenix.PubSub` after a write commits.

**A network service.** Licet runs inside one application and its database. It doesn't expose SpiceDB's gRPC or HTTP API, and other services can't call it. If several services in different languages need the same permissions, run SpiceDB.

**Read replicas and materialized permissions.** Every query reads the primary database through your repo, and permissions are computed when they are asked for.

## Differences from SpiceDB

Licet accepts the same schemas as SpiceDB with one exception. An arrow whose right-hand name isn't defined on any subject type of its relation is an error in Licet. SpiceDB only reports it as a lint warning.

Consistency tokens don't transfer between the two. A Licet token names a Postgres transaction in your database.

## Developing a validation file

`mix licet.validate` checks a SpiceDB validation file in the terminal. For a browser editor, the repository includes `examples/playground`, a small Phoenix app that checks the file as you type. See [Testing](testing.md).
