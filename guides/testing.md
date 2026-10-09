# Testing

`Licet.Testing.migrate!/2` creates the tables for one prefix. Use a distinct prefix per test so sandboxed tests do not see each other.

```elixir
setup do
  prefix = "t" <> Integer.to_string(System.unique_integer([:positive]))
  Licet.Testing.migrate!(MyApp.Repo, prefix)
  name = Module.concat(MyApp.LicetTest, "I" <> Integer.to_string(System.unique_integer([:positive])))

  start_supervised!({Licet, name: name, repo: MyApp.Repo, prefix: prefix, schema: {:string, schema}, gc_interval: false})

  %{licet: name}
end
```

With `Ecto.Adapters.SQL.Sandbox` in shared mode, checks on the test process see writes from that test. Set `gc_interval: false` so the collector does not run during the test.

`Licet.Testing.allow/3` lets a child process use the owner's sandbox connection. Parallel checks call the same sandbox allow helper.

## Validation files

`mix licet.validate test/conformance/document.yaml` runs a SpiceDB validation file against the in-memory engine. It is the YAML that [play.authzed.com](https://play.authzed.com) exports and `zed validate` reads: `schema`, `relationships`, `assertions` (`assertTrue`, `assertFalse`), and `validation`.

`validation` lists, for each `resource#permission`, every subject and the relations that hold it:

```yaml
validation:
  document:somedoc#view:
    - "[user:* - {user:jimmy}] is <document:somedoc#viewer>"
    - "[user:tom] is <document:somedoc#viewer>/<document:somedoc#writer>"
```

Licet builds the same set as SpiceDB's developer membership set: a recursive expand in which usersets are subjects too, and a wildcard keeps its exclusions next to concrete ids. Failures use SpiceDB's messages, for example ``For object and permission/relation `document:somedoc#view`, missing expected subject `user:jake` ``. `Licet.Validate.expected_relations/1` regenerates the section byte for byte as the playground writes it.

`examples/playground` is a local Phoenix app for editing a validation file in the browser. It checks the file with `Licet.Validate` on every change, imports and exports playground YAML, and recomputes expected relations. Run it with `mix setup && mix phx.server`. It needs no database.

## SpiceDB conformance

`test/conformance/spicedb/` vendors SpiceDB's consistency corpus (`internal/services/integrationtesting/testconfigs`) under its Apache-2.0 license. The commit is recorded in that directory's `LICENSE`. Every file is either run or skipped with the exact schema error it must produce. Today that means files using caveats and `use self`. No file is special-cased.

Each runnable file runs three ways:

- `Licet.Validate.run_file/1`: assertions and expected relations.
- `Licet.Conformance.run/1`, a port of SpiceDB's `consistencytestutil` suite on the in-memory reader. It checks every definition, object id, relation, and defined subject, then requires `lookup_resources` to return exactly the accessible set, `lookup_subjects` to contain the accessible subjects of each subject type and only subjects that check, every subject an expand reaches to check, and every assertion to agree with `lookup_resources`.
- Through Postgres: the schema and relationships go through `Licet.write/3`, then every assertion is checked at `consistency: :full` with `check/5`, `check_bulk/3`, and `lookup_resources/5`.

`test/licet/expected_relations_test.exs` ports the expected-relations fixtures from SpiceDB's `pkg/development/wasm/operations_test.go`.

## New Enemy

`test/licet/new_enemy_test.exs` is the token test from SpiceDB's `e2e/newenemy`, run on Postgres. With `permission allowed = direct - excluded`, it writes the exclusion, then the grant, and keeps both tokens. A check `{:exact, token}` at either token must deny. After the exclusion is deleted, the old tokens still deny and the newer token allows. Tokens carry the Postgres snapshot of the write, so a revision never shows the grant without the exclusion that came before it.

## SpiceDB differential

The tests tagged `:spicedb` run Licet and a live SpiceDB side by side, through SpiceDB's HTTP API. They are excluded by default.

- `test/licet/spicedb_live_corpus_test.exs` loads every runnable corpus file into both. It then asks every check over the file's definitions, object ids, and subjects, every LookupResources, and every LookupSubjects for each subject type the file writes, including wildcard exclusions. Any difference fails, whether or not the corpus has an assertion for it.
- `test/licet/validate_test.exs` compares generated check cases. The default count is 100, and CI sets `LICET_DIFFERENTIAL_CASES=10000`.

Start SpiceDB, then run the tagged tests:

```shell
docker run --rm -p 8443:8443 authzed/spicedb:latest \
  serve --datastore-engine memory --http-enabled --grpc-preshared-key test

LICET_SPICEDB=1 mix test --only spicedb --include spicedb
```

The [release binary](https://github.com/authzed/spicedb/releases) takes the same `serve` arguments if Docker is not available. `LICET_SPICEDB_URL` points the tests at another server. CI runs both suites against `authzed/spicedb:latest`.
