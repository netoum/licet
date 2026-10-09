defmodule LicetTest do
  use Licet.DataCase, async: false

  @schema """
  use expiration
  definition user {}
  definition team {
    relation member: user
  }
  definition document {
    relation owner: user
    relation viewer: user with expiration | user:* | team#member
    relation parent: document
    permission view = owner + viewer + parent->view
  }
  """

  test "looks up subjects of one type, like SpiceDB's LookupSubjects" do
    name =
      start_licet!("""
      definition user {}
      definition team {
        relation member: user
      }
      definition document {
        relation viewer: user | user:* | team#member
        relation banned: user
        permission view = viewer - banned
      }
      """)

    assert {:ok, _token} =
             Licet.write(name, [
               {:touch, "document:1#viewer@user:*"},
               {:touch, "document:1#viewer@user:cara"},
               {:touch, "document:1#viewer@team:eng#member"},
               {:touch, "team:eng#member@user:dan"},
               {:touch, "document:1#banned@user:eve"}
             ])

    assert {:ok, users, nil} = Licet.lookup_subjects(name, "document:1", "view", "user")

    assert users == [
             %{subject: "user:*", excluded: ["user:eve"]},
             %{subject: "user:cara", excluded: []},
             %{subject: "user:dan", excluded: []}
           ]

    assert {:ok, [%{subject: "team:eng#member", excluded: []}], nil} =
             Licet.lookup_subjects(name, "document:1", "view", "team#member")

    assert {:ok, [%{subject: "user:*"}], cursor} =
             Licet.lookup_subjects(name, "document:1", "view", "user", limit: 1)

    assert {:ok, [%{subject: "user:cara"}], _cursor} =
             Licet.lookup_subjects(name, "document:1", "view", "user", limit: 1, cursor: cursor)

    for bad <- ["User", "team#Member", "", 1] do
      assert {:error, %{reason: :invalid_filter}} =
               Licet.lookup_subjects(name, "document:1", "view", bad)
    end

    assert {:error, %{reason: :invalid_filter}} =
             Licet.lookup_subjects(name, "document:1", "view", "user", cursor: "nope")
  end

  test "writes, checks, reads, and deletes inside a transaction" do
    name = start_licet!(@schema)

    assert {:ok, token} =
             Licet.write(name, [
               {:create, "document:1#owner@user:ada"},
               {:touch, "document:2#viewer@user:bob"},
               {:touch, "document:2#viewer@user:bob"}
             ])

    assert {:ok, %{xid: _xid}} = Licet.Token.decode(token)
    assert {:ok, :allowed} = Licet.check(name, "document:1", "view", "user:ada")
    assert {:ok, :denied} = Licet.check(name, "document:1", "view", "user:bob")
    assert {:ok, ["2"], nil} = Licet.lookup_resources(name, "document", "view", "user:bob")

    assert {:ok, [%{subject: "user:ada", excluded: []}], nil} =
             Licet.lookup_subjects(name, "document:1", "view", "user")

    assert {:ok, :allowed, %{result: :allowed}} =
             Licet.explain(name, "document:1", "view", "user:ada")

    assert {:ok, rows} = Licet.read(name, %{resource_type: "document", resource_id: "1"})
    assert length(rows) == 1

    assert {:ok, _} =
             Licet.delete(name, %{resource_type: "document", resource_id: "1", relation: "owner"})

    assert {:ok, :denied} = Licet.check(name, "document:1", "view", "user:ada")
    assert {:error, %{reason: :invalid_filter}} = Licet.read(name, %{})
    assert {:error, %{reason: :invalid_filter}} = Licet.delete(name, %{})

    assert {:error, %{reason: :already_exists}} =
             Licet.write(name, [{:create, "document:2#viewer@user:bob"}])
  end

  test "enforces preconditions, import limits, expiration, and schema safety" do
    name = start_licet!(@schema)
    expires = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    text = "document:2#viewer@user:cara[expiration:#{DateTime.to_iso8601(expires)}]"

    assert {:error, %{reason: :precondition_failed}} =
             Licet.write(name, [{:create, "document:1#owner@user:ada"}],
               preconditions: [{:must_match, %{resource_type: "document"}}]
             )

    assert {:ok, _} =
             Licet.write(name, [{:create, "document:1#owner@user:ada"}],
               preconditions: [{:must_not_match, %{resource_type: "missing"}}]
             )

    assert {:ok, _} = Licet.import(name, [text])
    assert {:ok, :allowed} = Licet.check(name, "document:2", "view", "user:cara")
    limited = start_licet!(@schema, max_import: 1)

    assert {:error, %{reason: :too_many_updates}} =
             Licet.import(limited, ["document:9#owner@user:ada", "document:8#owner@user:ada"])

    assert {:error, %{reason: :invalid_relationship}} =
             Licet.write(name, [{:create, "document:1#owner@team:eng"}])

    assert {:error, %{reason: :unsafe_schema_change}} =
             Licet.write_schema(
               name,
               "definition user {}\ndefinition document {\n  relation viewer: user\n}"
             )
  end

  test "bulk checks keep order and multi writes share the transaction" do
    name = start_licet!(@schema)

    assert {:ok, result} =
             Ecto.Multi.new()
             |> Licet.Multi.write(name, :grant, [{:create, "document:4#owner@user:ada"}])
             |> Licet.TestRepo.transaction()

    assert "v1." <> _ = result.grant

    assert {:ok, [{:ok, :allowed}, {:error, %{reason: :invalid_relationship}}]} =
             Licet.check_bulk(name, [
               %{resource: "document:4", permission: "view", subject: "user:ada"},
               %{resource: "document:*", permission: "view", subject: "user:ada"}
             ])
  end

  test "committed tokens, cache, and garbage collection survive outside the sandbox" do
    prefix = "g" <> Integer.to_string(System.os_time(:native))

    name =
      Module.concat(Licet.Outside, "I" <> Integer.to_string(System.unique_integer([:positive])))

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Licet.TestRepo, fn ->
      Licet.Testing.migrate!(Licet.TestRepo, prefix)

      start_supervised!(
        {Licet,
         name: name,
         repo: Licet.TestRepo,
         prefix: prefix,
         schema: {:string, @schema},
         gc_interval: 60_000,
         quantization: 60_000}
      )

      assert {:ok, token} = Licet.write(name, [{:create, "document:8#owner@user:ada"}])

      assert {:ok, :allowed} =
               Licet.check(name, "document:8", "view", "user:ada", consistency: {:exact, token})

      assert {:ok, :allowed} =
               Licet.check(name, "document:8", "view", "user:ada",
                 consistency: {:at_least, token}
               )

      assert {:ok, :allowed} =
               Licet.check(name, "document:8", "view", "user:ada", consistency: :full)

      assert :ok = GenServer.call(Licet.Revision.name(name), :refresh)
      assert {:ok, :allowed} = Licet.check(name, "document:8", "view", "user:ada")
      assert {:ok, :allowed} = Licet.check(name, "document:8", "view", "user:ada")
      assert :ok = Licet.GC.collect(name)
      send(Licet.GC.name(name), :gc)
      send(Licet.Revision.name(name), :refresh)
      :sys.get_state(Licet.GC.name(name))
      :sys.get_state(Licet.Revision.name(name))
    end)
  end

  test "a rolled back token cannot be read" do
    prefix = "r" <> Integer.to_string(System.os_time(:native))

    name =
      Module.concat(Licet.Rollback, "I" <> Integer.to_string(System.unique_integer([:positive])))

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Licet.TestRepo, fn ->
      Licet.Testing.migrate!(Licet.TestRepo, prefix)

      start_supervised!(
        {Licet,
         name: name,
         repo: Licet.TestRepo,
         prefix: prefix,
         schema: {:string, @schema},
         gc_interval: false}
      )

      assert {:error, %{reason: :token_not_committed}} =
               Licet.TestRepo.transaction(fn ->
                 {:ok, token} = Licet.write(name, [{:create, "document:3#owner@user:ada"}])
                 Licet.TestRepo.rollback(token)
               end)
               |> then(fn {:error, token} ->
                 Licet.check(name, "document:3", "view", "user:ada", consistency: {:exact, token})
               end)
    end)
  end

  test "loads schemas from files, empty databases, and unsafe rewrites" do
    prefix = "s" <> Integer.to_string(System.unique_integer([:positive]))
    Licet.Testing.migrate!(Licet.TestRepo, prefix)
    path = "tmp/schema_#{prefix}.zed"
    File.write!(path, "definition user {}")

    name =
      Module.concat(
        Licet.FileSchema,
        "I" <> Integer.to_string(System.unique_integer([:positive]))
      )

    start_supervised!(
      {Licet,
       name: name, repo: Licet.TestRepo, prefix: prefix, schema: {:file, path}, gc_interval: false}
    )

    assert {:ok, _} = Licet.write(name, [])
    send(Licet.GC.name(name), :gc)
    :sys.get_state(Licet.GC.name(name))
    assert :ok = Licet.Sandbox.allow(Licet.TestRepo, self())
    assert :ok = Licet.Testing.allow(Licet.TestRepo, self(), self())
    File.rm(path)

    empty =
      Module.concat(
        Licet.EmptySchema,
        "I" <> Integer.to_string(System.unique_integer([:positive]))
      )

    empty_prefix = "e" <> Integer.to_string(System.unique_integer([:positive]))
    Licet.Testing.migrate!(Licet.TestRepo, empty_prefix)

    start_supervised!(
      {Licet,
       name: empty, repo: Licet.TestRepo, prefix: empty_prefix, schema: nil, gc_interval: false}
    )

    assert {:ok, _} = Licet.write_schema(empty, "definition user {}")

    assert {:error, reason} =
             start_supervised(
               {Licet,
                name: Licet.Missing.Instance,
                repo: Licet.TestRepo,
                prefix: "not_there",
                schema: nil,
                gc_interval: false}
             )

    assert inspect(reason) =~ "not_migrated"

    assert_raise Licet.Error, fn ->
      Licet.start_link(name: :unused, repo: Licet.TestRepo, prefix: "Bad")
    end

    assert {:error, %{reason: :invalid_relationship}} = Licet.write(name, [{:create, "nope"}])
    assert {:error, %{reason: :invalid_relationship}} = Licet.write(name, ["nope"])
    assert {:error, %{reason: :invalid_filter}} = Licet.write(name, [], preconditions: :nope)
    {:ok, rel} = Licet.Relationship.parse("document:1#viewer@user:ada")
    assert {:error, %{reason: :unknown_type}} = Licet.write(name, [{:create, rel}])
  end

  test "rejects stale tokens, narrowed schemas, and a second garbage collector" do
    prefix = "z" <> Integer.to_string(System.os_time(:native))

    name =
      Module.concat(Licet.Edges, "I" <> Integer.to_string(System.unique_integer([:positive])))

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Licet.TestRepo, fn ->
      Licet.Testing.migrate!(Licet.TestRepo, prefix)

      start_supervised!(
        {Licet,
         name: name,
         repo: Licet.TestRepo,
         prefix: prefix,
         schema: {:string, @schema},
         gc_interval: false}
      )

      assert %{} = Licet.Config.fetch!(name)

      assert {:error, %{reason: :invalid_config}} =
               Licet.check(name, "document:1", "view", "user:ada", consistency: :nope)

      assert {:error, %{reason: :token_invalid}} =
               Licet.check(name, "document:1", "view", "user:ada", consistency: {:exact, "nope"})

      stale = Licet.Token.encode(%{xid: "1", snapshot: "1:2:", at: DateTime.utc_now()})

      assert {:error, %{reason: reason}} =
               Licet.check(name, "document:1", "view", "user:ada", consistency: {:exact, stale})

      assert reason in [:snapshot_expired, :token_not_committed]

      assert {:ok, token} = Licet.write(name, [{:create, "document:1#owner@user:ada"}])
      assert :ok = GenServer.call(Licet.Revision.name(name), :refresh)

      assert {:ok, :allowed} =
               Licet.check(name, "document:1", "view", "user:ada",
                 consistency: {:at_least, token}
               )

      parent = self()

      task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.checkout(Licet.TestRepo, sandbox: false)

          Licet.TestRepo.transaction(fn ->
            {:ok, open} = Licet.write(name, [{:create, "document:9#owner@user:ada"}])
            send(parent, {:open, open})
            assert_receive :release_open, 1_000
            :ok
          end)
        end)

      assert_receive {:open, open}

      assert {:error, %{reason: :token_not_committed}} =
               Licet.check(name, "document:9", "view", "user:ada", consistency: {:exact, open})

      send(task.pid, :release_open)
      assert {:ok, :ok} = Task.await(task)

      expires = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      text = "document:2#viewer@user:cara[expiration:#{DateTime.to_iso8601(expires)}]"
      assert {:ok, _} = Licet.write(name, [{:create, text}])

      assert {:ok, _} =
               Licet.write(name, [{:touch, "document:2#viewer@user:cara"}],
                 preconditions: [{:must_match, %{resource_type: "document", resource_id: "2"}}]
               )

      later = DateTime.add(expires, 60, :second)

      assert {:ok, _} =
               Licet.write(name, [
                 {:touch, "document:2#viewer@user:cara[expiration:#{DateTime.to_iso8601(later)}]"}
               ])

      assert {:ok, _} = Licet.write(name, [{:delete, "document:1#owner@user:ada"}])

      key = :erlang.phash2({:licet_gc, prefix})

      assert {:error, %{reason: :token_invalid}} =
               Licet.Store.xid_visible?(Licet.TestRepo, "nope", "bad")

      assert_raise Licet.Error, fn -> Licet.Store.migrated?(Licet.TestRepo, "Bad") end
      Licet.TestRepo.query!("CREATE SCHEMA IF NOT EXISTS bare_schema")

      assert_raise Licet.Error, fn ->
        Licet.Store.list_relationships(Licet.TestRepo, "bare_schema", %{
          resource_type: "document",
          at: DateTime.utc_now(),
          snapshot: "1:2:",
          own_xid: ""
        })
      end

      assert {:ok, true} = Licet.Store.try_lock(Licet.TestRepo, key)
      assert :locked = Licet.GC.collect(name)
      assert :ok = Licet.Store.unlock(Licet.TestRepo, key)

      assert {:error, %{reason: :invalid_schema}} =
               start_supervised(
                 {Licet,
                  name: Licet.MissingFile.Instance,
                  repo: Licet.TestRepo,
                  prefix: prefix,
                  schema: {:file, "tmp/missing-#{prefix}.zed"},
                  gc_interval: false}
               )
               |> then(fn {:error, reason} ->
                 if inspect(reason) =~ "cannot read schema file",
                   do: {:error, %{reason: :invalid_schema}},
                   else: {:error, reason}
               end)
    end)
  end

  test "reports not started and invalid config" do
    assert {:error, %{reason: :not_started}} =
             Licet.check(:missing_licet, "document:1", "view", "user:ada")

    assert_raise Licet.Error, fn ->
      Licet.Config.new!(name: :bad, repo: Licet.TestRepo, prefix: "Bad")
    end

    assert_raise Licet.Error, fn ->
      Licet.Config.new!(name: :bad, repo: Licet.TestRepo, schema: {:nope, "x"})
    end

    assert :ok = Licet.Sandbox.allow(nil, self())
    assert :ok = Licet.Sandbox.allow(Licet.FakeRepo, self())
    assert :ok = Licet.Testing.allow(Licet.FakeRepo, self(), self())
  end
end
