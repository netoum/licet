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

`mix licet.validate test/conformance/document.yaml` runs a SpiceDB validation file against the in-memory engine. The file has `schema`, `relationships`, `assertTrue`, and `assertFalse`.

## SpiceDB differential

Set `LICET_SPICEDB=1` to compare generated cases with a local SpiceDB HTTP API. The default count is 100. CI sets `LICET_DIFFERENTIAL_CASES=10000`. The suite skips this unless the test is included with `--include spicedb`.

```shell
docker run --rm -p 8443:8443 authzed/spicedb:latest \
  serve --datastore-engine memory --http-enabled --grpc-preshared-key test
```
