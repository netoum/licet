# Transactions

`Licet.write/3`, `Licet.delete/3`, and `Licet.write_schema/3` join the caller's `Repo.transaction/2` when one is open. Otherwise they open their own transaction.

```elixir
MyApp.Repo.transaction(fn ->
  {:ok, token} = Licet.write(MyApp.Licet, [{:create, "document:1#owner@user:ada"}])
  {:ok, :allowed} = Licet.check(MyApp.Licet, "document:1", "view", "user:ada", consistency: {:exact, token})
end)
```

The check above sees the uncommitted tuple because it runs on the same connection. Another connection cannot use that token until the transaction commits. After a rollback the token is rejected.

`Licet.Multi.write/5` adds the same write as an `Ecto.Multi` step:

```elixir
Ecto.Multi.new()
|> Licet.Multi.write(MyApp.Licet, :grant, [{:create, "document:1#owner@user:ada"}])
|> MyApp.Repo.transaction()
```

Preconditions run in the write's transaction, at that write's snapshot:

```elixir
Licet.write(MyApp.Licet, [{:create, "document:1#owner@user:ada"}],
  preconditions: [{:must_not_match, %{resource_type: "document", resource_id: "1", relation: "owner"}}]
)
```

`must_match` fails when no living tuple fits the filter. `must_not_match` fails when one does. A failed precondition rolls the write back.
