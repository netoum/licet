# Licet playground

A local take on [play.authzed.com](https://play.authzed.com): edit a schema,
relationships, assertions, and expected relations, and Licet checks the file
on every change. It is a SpiceDB [validation file](https://authzed.com/docs/spicedb/modeling/validation-testing-debugging),
so you can import one exported from the SpiceDB playground, or copy this one
out and run it with `zed validate`.

It runs locally only and needs no database: every check goes through
`Licet.Validate`, which loads the relationships into an in-memory store.

```sh
mix setup
mix phx.server
```

Then open [localhost:4000](http://localhost:4000).

- **Check watches** list every `assertTrue` and `assertFalse` line with its
  outcome.
- **Expected relations** failures use SpiceDB's wording.
  **Recompute expected relations** replaces the section with what Licet
  derives, like the SpiceDB playground's "Update" button.
- **Explain a check** runs one `resource#permission@subject` through
  `Licet.Validate.explain/2` and shows the evaluation trace. It re-runs when
  you edit the file.
- Caveats are rejected, as they are everywhere in Licet.

The UI is built with [Corex](https://hexdocs.pm/corex). `mix test` covers the
import format and the LiveView.
