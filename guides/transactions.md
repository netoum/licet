# Transactions

Because Licet stores relationships in your database, its writes can be part of your own transactions. This is the main reason to embed authorization instead of calling a separate service: creating a record and granting access to it either both happen or neither does.

## Joining a transaction

`Licet.write/3`, `Licet.import/3`, `Licet.delete/3`, and `Licet.write_schema/3` join the caller's `Repo.transaction/2` when one is open on the same repo. Otherwise each opens its own transaction.

```elixir
MyApp.Repo.transaction(fn ->
  document = MyApp.Repo.insert!(changeset)

  {:ok, _token} =
    Licet.write(MyApp.Licet, [{:create, "document:#{document.id}#owner@user:#{user.id}"}])

  document
end)
```

If the insert raises or the transaction is rolled back, the relationship disappears with it.

A Licet write inside your transaction runs under a savepoint. If it fails, Licet undoes its own changes back to that savepoint and returns `{:error, %Licet.Error{}}`. Your transaction is still usable, and you decide what to do: roll back with `Repo.rollback/1`, or carry on.

```elixir
MyApp.Repo.transaction(fn ->
  case Licet.write(MyApp.Licet, [{:create, "document:1#owner@user:ada"}]) do
    {:ok, token} -> token
    {:error, %Licet.Error{} = error} -> MyApp.Repo.rollback(error)
  end
end)
```

## Reading your own writes

A check inside the transaction runs on the same connection and sees the uncommitted write:

```elixir
MyApp.Repo.transaction(fn ->
  {:ok, _token} = Licet.write(MyApp.Licet, [{:create, "document:1#owner@user:ada"}])
  {:ok, :allowed} = Licet.check(MyApp.Licet, "document:1", "edit", "user:ada")
end)
```

These checks skip the shared cache, because their answer depends on data nobody else can see yet.

Other connections can't see the write until the transaction commits. A token from an uncommitted write is rejected on another connection with `:token_not_committed`, and after a rollback it's rejected everywhere.

## Ecto.Multi

`Licet.Multi.write/5` adds a write as a named step of an `Ecto.Multi`:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:document, changeset)
|> Licet.Multi.write(MyApp.Licet, :grant, [{:create, "document:1#owner@user:ada"}])
|> MyApp.Repo.transaction()
#=> {:ok, %{document: %Document{}, grant: "v1.eyJ..."}}
```

The step's value is the write's token. When the updates depend on an earlier step, such as the id of an inserted row, use `Ecto.Multi.run/3`:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.insert(:document, changeset)
|> Ecto.Multi.run(:grant, fn _repo, %{document: document} ->
  Licet.write(MyApp.Licet, [{:create, "document:#{document.id}#owner@user:#{user.id}"}])
end)
|> MyApp.Repo.transaction()
```

A failing Licet step returns `{:error, :grant, %Licet.Error{}, changes_so_far}`, like any other step.

## Preconditions

A write can require that some relationships exist, or don't, at the moment it runs. Preconditions are checked inside the write's transaction, so nothing can change between the check and the write:

```elixir
Licet.write(
  MyApp.Licet,
  [{:create, "document:1#owner@user:ada"}],
  preconditions: [
    {:must_not_match, %{resource_type: "document", resource_id: "1", relation: "owner"}}
  ]
)
```

This creates an owner only if the document has none yet. `{:must_match, filter}` fails when no relationship matches the filter, and `{:must_not_match, filter}` fails when one does. A failed precondition returns `{:error, %Licet.Error{reason: :precondition_failed}}` and writes nothing.

A filter is a map with any of `:resource_type`, `:resource_id`, `:relation`, `:subject_type`, `:subject_id`, and `:subject_relation`.

## Atomic batches

All updates in one `Licet.write/3` call apply together, even outside a transaction. The default maximum is 1,000 updates per call (`max_updates`), and 10,000 for `Licet.import/3` (`max_import`). Split larger batches yourself, inside one `Repo.transaction/2` if they must be atomic.
