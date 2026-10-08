# Upgrade guide

## 1.0

1.0 is the first release. There is no previous Licet schema to migrate.

The database tables are created by `mix licet.gen.migration`. The migration is idempotent (`CREATE ... IF NOT EXISTS`) and `down` drops the prefix with `CASCADE`.

## Not in 1.0

The following are not implemented and will not be added as a silent change inside 1.x if they would break stored tuples:

* Watch and a LiveView subscription API
* Caveats and CEL
* `.all()`, `.any()`, and `self`
* A networked AuthZEN service, read replicas, and materialized permissions

A 1.x release may add optional APIs. It will not change the visibility rules or the token format without a major version. Token version `1` is the `v1.` prefix.
