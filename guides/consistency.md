# Consistency

Authorization data changes while your application runs: someone is shared on a document, someone leaves a team. Every check has to decide which version of that data to read. Reading the newest data is always correct but costs a database round trip and can't be cached. Reading a slightly older snapshot is faster and cacheable, but can miss a change made a moment ago.

Licet lets you choose per call, with the `:consistency` option.

## Tokens

Every write returns a token:

```elixir
{:ok, token} = Licet.write(MyApp.Licet, [{:create, "document:1#viewer@user:bob"}])
```

The token names the Postgres transaction that stored the write. It's an opaque string, safe to put in a session, a URL, or a job's arguments. Pass it back to a later call to say "read at least this write" or "read exactly what this write saw".

`Licet.delete/3` and `Licet.write_schema/3` return tokens too.

## Modes

| Mode | What a check reads | Cached |
| --- | --- | --- |
| `:minimize_latency` (default) | A snapshot shared by the instance, refreshed every `quantization` milliseconds (5 seconds by default) | yes |
| `{:at_least, token}` | The shared snapshot if it already includes the token's write, otherwise a fresh one | yes, outside a transaction |
| `{:exact, token}` | The snapshot recorded with the token's write | yes, outside a transaction |
| `:full` | A fresh snapshot of everything committed | no |

```elixir
Licet.check(MyApp.Licet, "document:1", "view", "user:bob")
Licet.check(MyApp.Licet, "document:1", "view", "user:bob", consistency: {:at_least, token})
Licet.check(MyApp.Licet, "document:1", "view", "user:bob", consistency: {:exact, token})
Licet.check(MyApp.Licet, "document:1", "view", "user:bob", consistency: :full)
```

The option works the same on `check/5`, `check_bulk/3`, `lookup_resources/5`, `lookup_subjects/5`, `explain/5`, and `read/3`.

## Choosing a mode

**`:minimize_latency`** suits most checks: page renders, API requests, list filtering. A change becomes visible to them within one refresh interval. Lower `quantization` to shorten that window, at the cost of more frequent snapshot queries and a less effective cache.

**`{:at_least, token}`** is for reading your own writes. After a user shares a document and is redirected to it, pass the token from the share so the next page is guaranteed to see it. It costs nothing extra when the shared snapshot is already new enough.

**`{:exact, token}`** answers a question as of a specific moment. Use it to reproduce a past decision, or to make several calls agree with each other. It returns `{:error, %Licet.Error{reason: :snapshot_expired}}` once garbage collection has removed that moment's history, after `gc_window` seconds (one day by default).

**`:full`** is for decisions where staleness is unacceptable, such as removing someone's access before deleting their data. It never uses the cache.

## The "new enemy" problem

Consider a document with one viewer, and two changes made in order: first Dan is banned from the document, then a secret is added to it. A check that sees the second change but not the first would let Dan read the secret.

Licet prevents this. A snapshot always contains a write together with every write that committed before it, so no mode can observe the secret without the ban. Tokens carry that guarantee across requests and nodes: a check `{:at_least, token}` with the secret's token is certain to see the ban.

## Inside a transaction

A check made inside an open `Repo.transaction/2` that has already written to the database reads on the transaction's own connection. It sees that transaction's uncommitted writes, whatever mode is requested (except `{:exact, token}`, which reads the token's snapshot), and it skips the cache. See [Transactions](transactions.md).

## Errors

| Reason | When |
| --- | --- |
| `:token_invalid` | The token is malformed or wasn't issued by Licet. |
| `:token_not_committed` | The token's transaction rolled back, or is still open on another connection. |
| `:snapshot_expired` | `{:exact, token}` for a moment older than `gc_window`. |
| `:invalid_config` | The `:consistency` value isn't one of the four modes. |

## Caching

The cache stores the answer of each check, keyed by the exact snapshot it was computed at. An answer computed at one snapshot is never served for another, so the cache can't make a check see older data than its mode allows. Errors aren't cached.
