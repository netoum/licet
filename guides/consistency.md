# Consistency

Every write returns a token. The token names the Postgres transaction that stored the tuples.

| Mode | What a check sees | Cache |
| --- | --- | --- |
| `:minimize_latency` (default) | The revision process's snapshot, refreshed on `quantization` (default 5s) | yes |
| `{:at_least, token}` | That revision when it already includes the token, otherwise a fresh snapshot | yes, outside a transaction |
| `{:exact, token}` | The snapshot stored for that token | no, while a transaction is open |
| `:full` | A new snapshot | no |

```elixir
{:ok, token} = Licet.write(MyApp.Licet, [{:create, "document:1#owner@user:ada"}])

Licet.check(MyApp.Licet, "document:1", "view", "user:ada", consistency: {:exact, token})
Licet.check(MyApp.Licet, "document:1", "view", "user:ada", consistency: {:at_least, token})
Licet.check(MyApp.Licet, "document:1", "view", "user:ada", consistency: :full)
```

`:minimize_latency` may be a few seconds behind a write that just committed. Pass the token from that write when the next check must see it.

`:exact` fails with `:token_not_committed` when the transaction aborted or is still open on another connection. It fails with `:snapshot_expired` when garbage collection has dropped the transaction row. It fails with `:token_invalid` when the token is malformed.

The cache key includes the snapshot. A newer revision does not reuse an older answer. Checks inside a transaction are not cached.
