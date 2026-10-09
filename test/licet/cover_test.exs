defmodule Licet.CoverTest do
  use Licet.DataCase, async: false

  @schema """
  use expiration
  definition user {}
  definition team {
    relation member: user
  }
  definition org {
    relation member: user
  }
  definition folder {
    relation owner: user
  }
  definition document {
    relation owner: user | user:* | team#member | org#member
    relation viewer: user with expiration
    permission view = owner + viewer
  }
  """

  test "rejects unsafe definition, expiration, and subject changes" do
    name = start_licet!(@schema)
    assert {:ok, _} = Licet.write(name, [{:create, "folder:1#owner@user:ada"}])

    assert {:error, %{reason: :unsafe_schema_change}} =
             Licet.write_schema(
               name,
               String.replace(@schema, ~r/definition folder \{[^}]+\}/, "")
             )

    expiring = start_licet!(@schema)

    expires = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    assert {:ok, _} =
             Licet.write(expiring, [
               {:create, "document:1#viewer@user:ada[expiration:#{DateTime.to_iso8601(expires)}]"}
             ])

    without_expiration =
      @schema
      |> String.replace("use expiration\n", "")
      |> String.replace("user with expiration", "user")

    assert {:error, %{message: message}} =
             Licet.write_schema(expiring, without_expiration)

    assert message =~ "expiration"

    narrowed = start_licet!(@schema)
    assert {:ok, _} = Licet.write(narrowed, [{:create, "document:1#owner@org:acme#member"}])
    shrunk = String.replace(@schema, " | org#member", "")

    assert {:error, %{message: narrow_message}} = Licet.write_schema(narrowed, shrunk)
    assert narrow_message =~ "no longer allows"

    compatible = start_licet!(@schema)
    assert {:ok, _} = Licet.write_schema(compatible, @schema <> "\n// note\n")

    {:ok, old} = Licet.Schema.parse(@schema)
    {:ok, newer} = Licet.Schema.parse(@schema)
    emptied = put_in(newer, [:definitions, "document", :relations, "owner", :subjects], [])
    prefix = Licet.Config.fetch!(compatible).prefix

    assert :ok = Licet.Store.ensure_compatible(Licet.TestRepo, prefix, old, emptied)
  end

  test "reloads schemas and collects deleted rows in batches" do
    name = start_licet!(@schema)
    config = Licet.Config.fetch!(name)
    assert {:error, %{reason: :not_started}} = Licet.SchemaServer.get(:licet_cover_missing)

    stop_supervised!(name)

    start_supervised!(
      {Licet,
       [
         name: name,
         repo: Licet.TestRepo,
         prefix: config.prefix,
         schema: {:string, @schema},
         gc_interval: false
       ]}
    )

    assert {:ok, _} = Licet.write_schema(name, @schema <> "\n// kept\n")

    assert {:ok, _} =
             Licet.TestRepo.transaction(fn ->
               Licet.Store.write_schema(Licet.TestRepo, config.prefix, "", "empty", %{})
             end)

    stop_supervised!(name)

    start_supervised!(
      {Licet,
       [
         name: name,
         repo: Licet.TestRepo,
         prefix: config.prefix,
         schema: {:string, @schema},
         gc_interval: false
       ]}
    )

    assert {:ok, _} =
             Licet.TestRepo.transaction(fn ->
               Licet.Store.write_schema(Licet.TestRepo, config.prefix, "!!!", "bad", %{})
             end)

    stop_supervised!(name)

    assert {:error, reason} =
             start_supervised(
               {Licet,
                [
                  name: name,
                  repo: Licet.TestRepo,
                  prefix: config.prefix,
                  schema: {:string, @schema},
                  gc_interval: false
                ]}
             )

    assert inspect(reason) =~ "invalid_schema"

    fresh = start_licet!(@schema)
    fresh_config = Licet.Config.fetch!(fresh)
    assert {:ok, _} = Licet.write(fresh, [{:create, "folder:9#owner@user:ada"}])
    stop_supervised!(fresh)
    reduced = String.replace(@schema, ~r/definition folder \{[^}]+\}/, "")

    assert {:error, unsafe} =
             start_supervised(
               {Licet,
                [
                  name: fresh,
                  repo: Licet.TestRepo,
                  prefix: fresh_config.prefix,
                  schema: {:string, reduced},
                  gc_interval: false
                ]}
             )

    assert inspect(unsafe) =~ "unsafe_schema_change"

    insert_deleted(config.prefix, "1")
    insert_deleted(config.prefix, "2")
    assert :ok = Licet.Store.collect(Licet.TestRepo, config.prefix, 86_400, 1)
    Licet.TestRepo.query!("DROP TABLE #{config.prefix}.relationships")

    assert {:error, %{reason: :not_migrated}} =
             Licet.Store.collect(Licet.TestRepo, config.prefix, 86_400, 1)
  end

  test "reads an exact token inside its transaction and rejects an unknown xid" do
    name = start_licet!(@schema)

    assert {:ok, {:ok, :allowed}} =
             Licet.TestRepo.transaction(fn ->
               {:ok, token} = Licet.write(name, [{:create, "document:3#owner@user:ada"}])

               Licet.check(name, "document:3", "view", "user:ada", consistency: {:exact, token})
             end)

    assert {:ok, token} = Licet.write(name, [{:create, "document:4#owner@user:ada"}])

    assert {:ok, :allowed} =
             Licet.check(name, "document:4", "view", "user:ada", consistency: {:at_least, token})

    assert {:error, %{reason: :invalid_relationship}} =
             Licet.check(name, "nope", "view", "user:ada")

    future = Licet.Token.encode(%{xid: "999999999999", snapshot: "1:2:", at: DateTime.utc_now()})

    assert {:error, %{reason: :token_invalid}} =
             Licet.check(name, "document:1", "view", "user:ada", consistency: {:exact, future})

    ancient = Licet.Token.encode(%{xid: "3", snapshot: "1:2:", at: DateTime.utc_now()})

    assert {:error, %{reason: :snapshot_expired}} =
             Licet.check(name, "document:1", "view", "user:ada", consistency: {:exact, ancient})
  end

  defp insert_deleted(prefix, id) do
    Licet.TestRepo.query!(
      """
      INSERT INTO #{prefix}.relationships
        (resource_type, resource_id, relation, subject_type, subject_id, subject_relation, created_xid, deleted_xid)
      VALUES ('document', $1, 'owner', 'user', 'ada', '', '1'::xid8, '1'::xid8)
      """,
      [id]
    )
  end
end
