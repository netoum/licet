# Testing

Licet stores everything in Postgres, so it works with the `Ecto.Adapters.SQL.Sandbox` you already use in tests. This guide shows two approaches, testing your application with a real instance and testing your permission model on its own.

## Using your application's instance

The simplest setup uses the instance your application already starts. Run the Licet migration in the test database like any other migration, and the sandbox isolates each test's writes:

```elixir
test "owners can edit their documents", %{user: user} do
  {:ok, document} = MyApp.Documents.create(user, %{title: "Plan"})

  assert {:ok, :allowed} =
           Licet.check(MyApp.Licet, "document:#{document.id}", "edit", "user:#{user.id}")
end
```

The check sees the test's uncommitted writes because, under the sandbox, the test runs inside a transaction. Start the instance with `gc_interval: false` in the test environment, so the garbage collector doesn't run during tests.

## One instance per test

For `async: true` tests that change the schema, or for testing a library built on Licet, start a separate instance per test with its own table prefix. `Licet.Testing.migrate!/2` creates the tables for a prefix:

```elixir
setup do
  prefix = "t#{System.unique_integer([:positive])}"
  Licet.Testing.migrate!(MyApp.Repo, prefix)

  name = Module.concat(MyApp.LicetTest, prefix)

  start_supervised!(
    {Licet,
     name: name,
     repo: MyApp.Repo,
     prefix: prefix,
     schema: {:file, "priv/licet/schema.zed"},
     gc_interval: false}
  )

  %{licet: name}
end

test "viewers can view", %{licet: licet} do
  {:ok, _token} = Licet.write(licet, [{:create, "document:1#viewer@user:ada"}])
  assert {:ok, :allowed} = Licet.check(licet, "document:1", "view", "user:ada")
end
```

The tables are created inside the test's sandbox transaction, so they disappear when the test ends.

## Processes and the sandbox

Licet runs its queries in the calling process, so a check from the test process uses the test's sandbox connection. When your own code calls Licet from a process the test spawned, give that process access with `Licet.Testing.allow/3`:

```elixir
test_pid = self()

Task.async(fn ->
  Licet.Testing.allow(MyApp.Repo, test_pid, self())
  Licet.check(MyApp.Licet, "document:1", "view", "user:ada")
end)
```

With the sandbox in shared mode, `Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})`, no allowance is needed.

## Testing the permission model

A permission model deserves its own tests, independent of the rest of the application. Licet runs SpiceDB validation files, the YAML that the [SpiceDB playground](https://play.authzed.com) exports and `zed validate` reads:

```yaml
schema: |-
  definition user {}

  definition document {
    relation owner: user
    relation viewer: user | user:*
    permission view = owner + viewer
  }

relationships: |-
  document:roadmap#owner@user:ada
  document:roadmap#viewer@user:bob

assertions:
  assertTrue:
    - "document:roadmap#view@user:ada"
    - "document:roadmap#view@user:bob"
  assertFalse:
    - "document:roadmap#view@user:cara"

validation:
  document:roadmap#view:
    - "[user:ada] is <document:roadmap#owner>"
    - "[user:bob] is <document:roadmap#viewer>"
```

* `assertions` lists checks that must be allowed (`assertTrue`) or denied (`assertFalse`).
* `validation` lists, for each `resource#permission`, every subject that has it and the relations that grant it. A wildcard is written with its exclusions, as in `[user:* - {user:dan}]`.

Run a file from the command line, for example in CI:

```shell
mix licet.validate test/permissions/documents.yaml
```

Or from ExUnit:

```elixir
test "document permissions" do
  assert :ok = Licet.Validate.run_file("test/permissions/documents.yaml")
end
```

Failures use the same messages as SpiceDB. The file runs in memory and doesn't need a database.

Writing the `validation` section by hand is tedious. `Licet.Validate.expected_relations/1` computes it from the schema and relationships, in the same format the playground writes, so you can review it once and commit it.

`Licet.Validate.explain/2` explains one assertion line against the YAML file. For a running instance and Postgres relationships, use `Licet.explain/5` instead; see [Operations](operations.md).

| Function | Relationships | When to use |
| --- | --- | --- |
| `Licet.Validate.explain/2` | Validation YAML (in memory) | This guide, CI, the playground |
| `Licet.explain/5` | A running Licet instance | Production debugging |

## A playground

The repository includes `examples/playground`, a small Phoenix app for editing a validation file in the browser. It checks the file as you type, imports and exports playground YAML, recomputes the expected relations, and explains one check with `Licet.Validate.explain/2`. It needs no database:

```shell
cd examples/playground
mix setup
mix phx.server
```
