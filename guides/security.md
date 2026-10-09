# Security

Authorization code is security code. This page explains how Licet handles untrusted input and what remains your responsibility.

## Your responsibilities

**Authenticate first.** Licet answers whether a subject has a permission. It doesn't know who the current user is. Build the subject string from the authenticated user, such as `"user:#{current_user.id}"`, never from request parameters.

**Fail closed.** Treat `{:error, _}` from a check as a denial. A check can fail because of a timeout, a depth limit, or a database problem, and none of those should grant access.

```elixir
case Licet.check(MyApp.Licet, resource, "edit", subject) do
  {:ok, :allowed} -> :ok
  _denied_or_error -> {:error, :forbidden}
end
```

**Check on every action that changes data.** A LiveView that checked on mount should check again before handling an event that writes. See [Phoenix integration](phoenix.md).

**Choose the consistency mode deliberately.** The default can be a few seconds behind. Revoking access and then immediately relying on the revocation needs a token or `:full`. See [Consistency](consistency.md).

**Pick the instance name in code.** The instance name is an atom chosen by your application, never derived from user input.

## Untrusted input

Licet treats schema text, object ids, relationship text, tokens, and cursors as untrusted data.

* **No atoms.** Type, relation, and permission names stay strings. Licet never creates atoms from input, so it can't exhaust the atom table.
* **No term decoding.** Tokens and cursors are base64-encoded JSON, validated by shape, and tokens have a size limit. Neither is ever passed to `:erlang.binary_to_term/1`.
* **Parameterized SQL.** Every value is a query parameter. The only interpolated identifier is the table prefix, which is validated against `^[a-z_][a-z0-9_]{0,62}$` when the instance starts.
* **Validated ids.** An object id is `*` or 1 to 1024 characters from `[A-Za-z0-9/_|=\-+]`. A resource can't be a wildcard.
* **Safe YAML.** Validation files are read with `atoms: false`.

Tokens and cursors aren't secret and aren't signed. A forged token can at most ask for a snapshot that exists or fail with `:token_invalid`; it can't grant access.

## Resource limits

Every query and write is bounded by the instance options, so one request can't monopolize the database:

| Option | Bounds | Default |
| --- | --- | --- |
| `max_updates` | updates in one `Licet.write/3` | 1,000 |
| `max_import` | relationships in one `Licet.import/3` | 10,000 |
| `max_preconditions` | preconditions on one write | 1,000 |
| `max_depth` | arrow and userset hops in one check | 50 |
| `max_lookup` | results computed by one lookup | 10,000 |
| `timeout` | milliseconds for one check or lookup | 5,000 |

Lower them if your schema doesn't need the headroom.

## Data integrity

* **Schema changes are checked.** `Licet.write_schema/3`, and starting an instance with a new schema, fail with `:unsafe_schema_change` when the new schema would ignore relationships that are still stored, such as removing a relation that has data. Delete the relationships first, then change the schema.
* **Cache answers are scoped to a snapshot.** A cached answer is only reused for the exact snapshot it was computed at. Errors aren't cached, and checks inside a transaction or with `:full` don't use the cache.
* **History is kept for `gc_window`.** Garbage collection keeps every transaction newer than `gc_window` seconds, so a token from that window can still be read exactly.

## Reporting a vulnerability

Report security issues privately to the maintainers listed in the repository, before opening a public issue.
