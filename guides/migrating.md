# Migrating

Licet and SpiceDB can share a `.zed` file when that file stays inside the [supported subset](zed.md).

## From SpiceDB

1. Export the schema text and confirm `Licet.Schema.parse/1` accepts it.
2. Generate a Licet migration in the application database. Licet does not read SpiceDB's tables.
3. Rewrite tuples into `resource:id#relation@subject:id` and load them with `Licet.import/2`.
4. Point checks at `Licet.check/4` using the same resource, permission, and subject strings.
5. Keep SpiceDB available until the imported tuples and the checks agree. `mix licet.validate` runs the same YAML files SpiceDB's validation command accepts, for the supported assertions.

`import/2` only creates. It fails if a tuple is already present. Deletes and touches go through `write/3`.

## To SpiceDB

Export living tuples with `Licet.read/2` and write them to SpiceDB. The schema text stored by Licet is the source that was written, so it can be sent to SpiceDB's schema API when it uses only the shared subset.

Tokens do not transfer. A Licet token names a Postgres xid in your database. SpiceDB has its own Zed tokens.
