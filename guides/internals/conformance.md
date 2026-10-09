# Conformance testing

Licet aims to give the same answers as SpiceDB for every schema it accepts. This page describes how that is tested. It's written for contributors; you don't need it to use Licet.

## SpiceDB's consistency corpus

`test/conformance/spicedb/` vendors SpiceDB's consistency corpus (`internal/services/integrationtesting/testconfigs`) under its Apache-2.0 license. The upstream commit is recorded in that directory's `LICENSE`.

Every file in the corpus is either run or skipped. A skipped file must fail to parse with the exact error recorded for it, which today means files that use caveats or `use self`. No file is special-cased.

Each runnable file runs three ways:

* **Assertions and expected relations**, through `Licet.Validate.run_file/1`.
* **Exhaustive consistency**, through `Licet.Conformance.run/1`, a port of SpiceDB's `consistencytestutil` suite on the in-memory reader. It checks every combination of definition, object id, relation, and subject in the file. It then requires `lookup_resources` to return exactly the accessible resources, `lookup_subjects` to return the accessible subjects of each subject type and only subjects that check, every subject reached by an expand to check, and every assertion to agree with `lookup_resources`.
* **Through Postgres.** The schema and relationships go through `Licet.write/3`, then every assertion is checked at `consistency: :full` with `check/5`, `check_bulk/3`, and `lookup_resources/5`.

`test/licet/expected_relations_test.exs` ports the expected-relations fixtures from SpiceDB's `pkg/development/wasm/operations_test.go`.

## New enemy

`test/licet/new_enemy_test.exs` ports the token test from SpiceDB's `e2e/newenemy` and runs it on Postgres. With `permission allowed = direct - excluded`, it writes the exclusion, then the grant, keeping both tokens. A check `{:exact, token}` at either token must deny. After the exclusion is deleted, the old tokens still deny and the newer token allows.

The test found a real bug: the check cache was keyed on the snapshot text alone, and a write's recorded snapshot can equal an autocommit snapshot taken just before the write. Cache keys now carry the whole revision.

## Differential testing against a live SpiceDB

Tests tagged `:spicedb` run Licet and a live SpiceDB side by side, through SpiceDB's HTTP API. They are excluded by default.

* `test/licet/spicedb_live_corpus_test.exs` loads every runnable corpus file into both. It then compares every check over the file's definitions, object ids, and subjects, every LookupResources, and every LookupSubjects for each subject type the file writes, including wildcard exclusions. Any difference fails, whether or not the corpus has an assertion for it.
* `test/licet/validate_test.exs` compares generated check cases. The default count is 100; CI sets `LICET_DIFFERENTIAL_CASES=10000`.

Start SpiceDB, then run the tagged tests:

```shell
docker run --rm -p 8443:8443 authzed/spicedb:latest \
  serve --datastore-engine memory --http-enabled --grpc-preshared-key test

LICET_SPICEDB=1 mix test --only spicedb --include spicedb
```

The [release binary](https://github.com/authzed/spicedb/releases) takes the same `serve` arguments if Docker isn't available. `LICET_SPICEDB_URL` points the tests at another server. CI runs both suites against `authzed/spicedb:latest` on every push.
