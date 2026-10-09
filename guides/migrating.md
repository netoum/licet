# Migrating to or from SpiceDB

Licet and SpiceDB read the same schema language and the same relationship format, so moving between them is mostly a matter of copying data. This guide covers both directions.

Before you start, check that your schema stays inside what Licet supports. [Limitations](limitations.md) lists the differences, chiefly caveats and `self`.

## From SpiceDB to Licet

**1. Check the schema.** Export it with `zed schema read`, then parse it with Licet:

```elixir
{:ok, schema} = Licet.Schema.parse(File.read!("schema.zed"))
```

An unsupported feature fails with `:invalid_schema` and names the feature.

**2. Create the tables** in your application's database:

```shell
mix licet.gen.migration
mix ecto.migrate
```

**3. Start an instance** with the schema, as in [Getting started](getting-started.md).

**4. Copy the relationships.** Export them from SpiceDB in the text form `resource:id#relation@subject:id`, for example with `zed relationship read`, and load them in batches with `Licet.import/3`:

```elixir
"relationships.txt"
|> File.stream!()
|> Stream.map(&String.trim/1)
|> Stream.reject(&(&1 == ""))
|> Stream.chunk_every(10_000)
|> Enum.each(fn batch -> {:ok, _token} = Licet.import(MyApp.Licet, batch) end)
```

`Licet.import/3` only creates relationships and fails with `:already_exists` if one is already stored. Each batch is atomic, so a failed batch can be retried after you fix it.

**5. Compare before switching.** Keep SpiceDB running and send the same checks to both, through `Licet.check/5` and your SpiceDB client, until they agree. A SpiceDB validation file with assertions is a convenient way to test the model itself: `mix licet.validate` runs it against Licet.

**6. Switch reads, then writes.** Point checks and lookups at Licet. Once you're confident, move writes too and retire SpiceDB.

## From Licet to SpiceDB

**1. Copy the schema.** The text you gave Licet is valid SpiceDB schema. Write it with `zed schema write`.

**2. Export the relationships.** `Licet.read/3` returns the stored relationships that match a filter, which must name at least one field. Read each resource type and print the text form:

```elixir
for type <- ["document", "folder", "team"] do
  {:ok, relationships} =
    Licet.read(MyApp.Licet, %{resource_type: type}, consistency: :full)

  Enum.map(relationships, &Licet.Relationship.to_string/1)
end
```

Then import the lines into SpiceDB, for example with `zed import` or the `WriteRelationships` API.

## Tokens

Consistency tokens don't transfer in either direction. A Licet token names a transaction in your Postgres database, and SpiceDB issues its own ZedTokens. After a migration, start with fresh tokens.
