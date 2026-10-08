# Benchmarks

`bench/check.exs` measures an in-memory check of a direct relation. It does not open Postgres. Run it from the project root:

```shell
mix run bench/check.exs
```

The script uses Benchee for a one-second pass so it can be re-run locally. Treat the numbers as a baseline for the evaluator, not as a database round trip.

A direct `view = owner` check on one tuple is a few microseconds on a single BEAM. A check that walks an arrow or a userset adds one reader lookup per hop. Postgres latency dominates once `Licet.Reader.Postgres` is used, because each hop is a parameterized `SELECT`.

The ETS cache removes that cost for a repeated check against the same snapshot. `:full` and checks inside a transaction do not use the cache, on purpose.
