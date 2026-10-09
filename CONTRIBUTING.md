# Contributing

Thank you for helping improve Licet. Issues and pull requests are welcome.

## Setting up

You need Elixir 1.17 or newer and Postgres 15 or newer. The test suite connects to `127.0.0.1:54329` by default; set `PGPORT`, `PGUSER`, `PGPASSWORD`, and `PGDATABASE` to use another server.

```shell
mix deps.get
mix test
```

Tests log at `:warning`. To see every query, set `config :logger, level: :debug` in `config/test.exs` temporarily.

## Before opening a pull request

Run the same checks as CI:

```shell
mix format --check-formatted
mix compile --warnings-as-errors
mix test --cover
mix credo --strict
mix docs --warnings-as-errors
mix dialyzer
```

Coverage must stay at 100%.

## Comparing with SpiceDB

Licet's answers are tested against SpiceDB's own test corpus, and against a live SpiceDB server in CI. If you change how checks or lookups are evaluated, run the live comparison too. [Conformance testing](guides/internals/conformance.md) explains the suites and how to start SpiceDB locally.

## Examples

`examples/blog` and `examples/playground` are separate Mix projects with their own CI jobs. Run `mix test` inside each one if you change the public API.

## Changelog

Don't edit `CHANGELOG.md` in a pull request; maintainers update it when releasing.

## Code of Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
