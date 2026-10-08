# Contributing

Issues and pull requests are welcome.

Before opening a pull request, run:

```shell
mix format
mix test --cover
mix credo --strict
```

Postgres 15 or newer must be reachable. The test suite defaults to `127.0.0.1:54329`. See [Testing](guides/testing.md).

Do not edit `CHANGELOG.md` in a contributor pull request; maintainers will update it.

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
