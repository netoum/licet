defmodule Licet.GapsTest do
  use ExUnit.Case, async: true

  test "dispatch deduplicates, times out, and keeps errors" do
    name = Module.concat(Licet.Gaps, "I" <> Integer.to_string(System.unique_integer([:positive])))
    start_supervised!({Licet.Cache, %{name: name}})
    start_supervised!({Registry, keys: :unique, name: Module.concat(name, Registry)})

    assert :miss = Licet.Cache.fetch(name, :missing)
    assert {:ok, :allowed} = Licet.Dispatch.compute(name, :once, 1_000, fn -> {:ok, :allowed} end)

    assert {:ok, :allowed} =
             Licet.Cache.fetch(name, {nil, nil, nil, nil})
             |> then(fn _ ->
               Licet.Dispatch.compute(name, :once, 1_000, fn -> {:ok, :denied} end)
             end)

    parent = self()

    holder =
      Task.async(fn ->
        Licet.Dispatch.compute(name, :slow, 1_000, fn ->
          send(parent, :holding)
          assert_receive :release, 1_000
          {:ok, :allowed}
        end)
      end)

    assert_receive :holding

    waiter =
      Task.async(fn ->
        Licet.Dispatch.compute(name, :slow, 1_000, fn -> {:ok, :denied} end)
      end)

    Process.sleep(50)
    send(holder.pid, :release)
    assert {:ok, :allowed} = Task.await(holder)
    assert {:ok, :allowed} = Task.await(waiter)

    stalled =
      Task.async(fn ->
        Licet.Dispatch.compute(name, :stuck, 50, fn ->
          send(parent, :stuck)
          assert_receive :never, 1_000
          {:ok, :allowed}
        end)
      end)

    assert_receive :stuck

    timed =
      Task.async(fn ->
        Licet.Dispatch.compute(name, :stuck, 50, fn -> {:ok, :denied} end)
      end)

    assert {:error, %{reason: :timeout}} = Task.await(timed)
    send(stalled.pid, :never)
    assert {:ok, :allowed} = Task.await(stalled)

    error = Licet.Error.new(:cycle, "cycle")
    assert {:error, ^error} = Licet.Dispatch.compute(name, :bad, 1_000, fn -> {:error, error} end)
  end

  test "config, errors, migrations, and validation edges" do
    assert_raise Licet.Error, fn -> Licet.Config.fetch!(:not_running) end

    assert %{schema: {:file, "priv/schema.zed"}} =
             Licet.Config.new!(
               name: :file_cfg,
               repo: Licet.FakeRepo,
               schema: {:file, "priv/schema.zed"}
             )

    assert Licet.Error.message(
             Licet.Error.exception(reason: :timeout, message: "timed out", details: %{})
           ) == "timed out"

    assert_raise Licet.Error, fn -> Licet.Migration.statements("Bad") end
    assert {:error, %{reason: :invalid_schema}} = Licet.Validate.run_file("missing.yaml")

    assert {:error, %{reason: :invalid_relationship}} =
             Licet.Validate.run("schema: |\n  definition user {}\nrelationships: |\n  nope\n")

    yaml =
      "schema: |\n  definition user {}\n  definition document {\n    relation viewer: user\n    permission view = viewer\n  }\nassertions:\n  assertTrue:\n    - nope\n"

    assert {:error, [%{expected: :allowed}]} = Licet.Validate.run(yaml)

    assert_raise Mix.Error, fn -> Mix.Tasks.Licet.Validate.run([]) end
    assert_raise Mix.Error, fn -> Mix.Tasks.Licet.Validate.run(["missing.yaml"]) end
    denied = "tmp/denied.yaml"

    File.write!(
      denied,
      "schema: |\n  definition user {}\n  definition document {\n    relation viewer: user\n    permission view = viewer\n  }\nassertions:\n  assertTrue:\n    - document:1#view@user:ada\n"
    )

    assert_raise Mix.Error, fn -> Mix.Tasks.Licet.Validate.run([denied]) end
    File.rm(denied)

    path = "tmp/001_install_licet.exs"
    File.rm(path)
    Mix.Task.rerun("licet.gen.migration", ["--path", path])
    assert File.read!(path) =~ "Licet.Migration.up"
    File.rm(path)
    Mix.Task.rerun("licet.gen.migration", [])
    [generated | _] = Path.wildcard("priv/repo/migrations/*_install_licet.exs")
    File.rm(generated)

    pg = %Postgrex.Error{postgres: %{code: :unique_violation}}
    assert {:error, %{reason: :already_exists}} = Licet.Store.exception_result(pg)
    missing = %Postgrex.Error{postgres: %{code: :undefined_table}}
    assert {:error, %{reason: :not_migrated}} = Licet.Store.exception_result(missing)
    bad = %Postgrex.Error{postgres: %{code: :invalid_text_representation}}
    assert {:error, %{reason: :token_invalid}} = Licet.Store.exception_result(bad)

    assert_raise RuntimeError, fn ->
      Licet.Store.exception_result(%RuntimeError{message: "nope"})
    end
  end

  test "rules reject unknown types, wildcards, and expiration" do
    {:ok, schema} =
      Licet.Schema.parse(
        "definition user {}\ndefinition team {\n  relation member: user\n}\ndefinition document {\n  relation viewer: user | user:* | team#member\n}"
      )

    {:ok, rel} = Licet.Relationship.parse("document:1#viewer@user:*")
    assert :ok = Licet.Rules.relationship(schema, rel)
    {:ok, member} = Licet.Relationship.parse("document:1#viewer@team:eng#member")
    assert :ok = Licet.Rules.relationship(schema, member)
    {:ok, missing} = Licet.Relationship.parse("missing:1#viewer@user:ada")
    assert {:error, %{reason: :unknown_type}} = Licet.Rules.relationship(schema, missing)
    {:ok, owner} = Licet.Relationship.parse("document:1#owner@user:ada")
    assert {:error, %{reason: :unknown_relation}} = Licet.Rules.relationship(schema, owner)
    {:ok, bad_subject} = Licet.Relationship.parse("document:1#viewer@user:ada#member")

    assert {:error, %{reason: :invalid_relationship}} =
             Licet.Rules.relationship(schema, bad_subject)

    {:ok, plain} =
      Licet.Schema.parse("definition user {}\ndefinition document {\n  relation viewer: user\n}")

    {:ok, expired} =
      Licet.Relationship.parse("document:1#viewer@user:ada[expiration:2030-01-01T00:00:00Z]")

    assert {:error, %{reason: :invalid_relationship}} = Licet.Rules.relationship(plain, expired)

    {:ok, expiring} =
      Licet.Schema.parse(
        "use expiration\ndefinition user {}\ndefinition document {\n  relation viewer: user\n}"
      )

    assert {:error, %{message: message}} = Licet.Rules.relationship(expiring, expired)
    assert message =~ "expiration"

    past = %{expired | expires_at: ~U[2000-01-01 00:00:00Z]}
    future = %{expired | expires_at: ~U[2099-01-02 00:00:00Z]}
    reader = %Licet.Reader.Memory{tuples: [past, future]}
    listed = Licet.Reader.list(reader, %{at: ~U[2099-01-01 00:00:00Z]})
    assert listed == [future]

    definition = %{
      kind: :definition,
      name: "Bad",
      offset: 0,
      segments: ["Bad"],
      members: [
        %{
          name: "BadRel",
          offset: 1,
          subjects: [
            %{
              type: "Bad",
              offset: 2,
              segments: ["Bad"],
              wildcard: false,
              relation: "Bad",
              expiration: false
            }
          ]
        },
        %{
          kind: :permission,
          name: "BadPerm",
          offset: 3,
          expr: {:arrow, {:union, {:name, "a", 4}, {:name, "b", 5}}, {:name, "c", 6}}
        }
      ]
    }

    assert {:error, errors} =
             Licet.Schema.Validator.validate([:use_expiration, :use_expiration, definition], "x")

    assert errors != []
  end
end
