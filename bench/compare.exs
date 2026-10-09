# Compares Licet with a SpiceDB server on the same machine and the same
# Postgres server. See guides/internals/benchmarks.md.
#
#     MIX_ENV=test mix run bench/compare.exs
#
# BENCH_TIME and BENCH_WARMUP set Benchee's seconds per job (defaults 5 and 2).

defmodule Licet.Bench.Repo do
  use Ecto.Repo, otp_app: :licet, adapter: Ecto.Adapters.Postgres
end

defmodule Licet.Bench do
  alias Licet.Bench.Repo
  alias Licet.SpiceDB

  @prefix "bench"

  @schema """
  definition user {}

  definition group {
    relation member: user | group#member
  }

  definition folder {
    relation parent: folder
    relation viewer: user | group#member
    permission view = viewer + parent->view
  }

  definition document {
    relation parent: folder
    relation owner: user
    relation viewer: user | group#member
    permission view = owner + viewer + parent->view
  }
  """

  def run do
    {:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql, :req])
    url = SpiceDB.url()
    reachable!(url)

    relationships = dataset()
    IO.puts("Loading #{length(relationships)} relationships into Licet and SpiceDB")
    start_licet!(relationships)
    parsed = Enum.map(relationships, fn text -> elem(Licet.Relationship.parse(text), 1) end)
    :ok = SpiceDB.load(url, @schema, parsed)

    time = env_integer("BENCH_TIME", 5)
    warmup = env_integer("BENCH_WARMUP", 2)

    full = measure("full", scenarios(url, [consistency: :full], :full), time, warmup)

    # Both sides serve :minimize_latency from a snapshot refreshed every 5 seconds.
    Process.sleep(6_000)
    default = measure("default", scenarios(url, [], :minimize_latency), time, warmup)

    churn!(url)

    churned =
      measure("full, after churn", scenarios(url, [consistency: :full], :full), time, warmup)

    print_table(full ++ default ++ churned)
  end

  # Grants and revokes 100,000 relationships on documents no scenario reads, so
  # both systems keep that many deleted rows until garbage collection.
  defp churn!(url) do
    churn = for n <- 1..100_000, do: "document:churn#{n}#viewer@user:churn"
    IO.puts("\nGranting and revoking #{length(churn)} relationships")

    churn
    |> Enum.chunk_every(10_000)
    |> Enum.each(fn chunk -> {:ok, _token} = Licet.import(Licet.Bench.Licet, chunk) end)

    {:ok, _token} =
      Licet.delete(Licet.Bench.Licet, %{
        resource_type: "document",
        subject_type: "user",
        subject_id: "churn"
      })

    parsed = Enum.map(churn, fn text -> elem(Licet.Relationship.parse(text), 1) end)
    :ok = SpiceDB.write(url, parsed)
    :ok = SpiceDB.delete(url, parsed)
  end

  defp measure(mode, scenarios, time, warmup) do
    Enum.each(scenarios, &agree!(mode, &1))

    for scenario <- scenarios, parallel <- [1, 8] do
      IO.puts("\n== #{scenario.name}, #{mode} consistency, parallel #{parallel}")

      suite =
        Benchee.run(%{"Licet" => scenario.licet, "SpiceDB" => scenario.spicedb},
          time: time,
          warmup: warmup,
          parallel: parallel,
          memory_time: 0,
          percentiles: [50, 99],
          print: [configuration: false]
        )

      {mode, scenario.name, parallel, stats(suite)}
    end
  end

  # 1,000 users and 100 groups of 20, where groups g0..g49 also contain group
  # g50..g99. Folders form a three-level tree: 10 roots, 100 middle folders and
  # 1,000 leaves; root rN is viewable by group gN. 10,000 documents sit in the
  # leaves, each with an owner, and every fifth with a direct viewer. User u999
  # can view middle folder m99.
  defp dataset do
    groups =
      for g <- 0..99, k <- 0..19, do: "group:g#{g}#member@user:u#{rem(g * 10 + k, 1000)}"

    nested = for g <- 0..49, do: "group:g#{g}#member@group:g#{g + 50}#member"

    folders =
      for(m <- 0..99, do: "folder:m#{m}#parent@folder:r#{div(m, 10)}") ++
        for(l <- 0..999, do: "folder:l#{l}#parent@folder:m#{div(l, 10)}") ++
        for(r <- 0..9, do: "folder:r#{r}#viewer@group:g#{r}#member") ++
        ["folder:m99#viewer@user:u999"]

    documents =
      for d <- 0..9_999, reduce: [] do
        acc ->
          viewer =
            if rem(d, 5) == 0, do: ["document:d#{d}#viewer@user:u#{rem(d * 7, 1000)}"], else: []

          viewer ++
            [
              "document:d#{d}#parent@folder:l#{div(d, 10)}",
              "document:d#{d}#owner@user:u#{rem(d, 1000)}"
              | acc
            ]
      end

    groups ++ nested ++ folders ++ documents
  end

  # Each scenario runs the same request on both sides and returns comparable answers.
  defp scenarios(url, opts, consistency) do
    bulk = for d <- 950..1049, do: {"document:d#{d}", "view", "user:u505"}

    [
      check("direct check (owner)", url, opts, consistency, "document:d42", "user:u42"),
      check(
        "nested check (3 folders, nested group)",
        url,
        opts,
        consistency,
        "document:d500",
        "user:u505"
      ),
      check("denied check", url, opts, consistency, "document:d500", "user:u999"),
      %{
        name: "check_bulk (100 items)",
        licet: fn ->
          checks = for {r, p, s} <- bulk, do: %{resource: r, permission: p, subject: s}
          {:ok, results} = Licet.check_bulk(Licet.Bench.Licet, checks, opts)
          Enum.map(results, fn {:ok, answer} -> answer == :allowed end)
        end,
        spicedb: fn ->
          requests = for {r, p, s} <- bulk, do: {object(r), p, subject(s)}
          {:ok, results} = SpiceDB.check_bulk(url, requests, consistency)
          Enum.map(results, fn {:ok, answer} -> answer end)
        end
      },
      %{
        name: "lookup_resources (109 of 10,000)",
        licet: fn ->
          {:ok, ids, nil} =
            Licet.lookup_resources(
              Licet.Bench.Licet,
              "document",
              "view",
              "user:u999",
              Keyword.put(opts, :limit, 10_000)
            )

          MapSet.new(ids)
        end,
        spicedb: fn ->
          {:ok, ids} =
            SpiceDB.lookup_resources(url, "document", "view", {"user", "u999", ""}, consistency)

          ids
        end
      }
    ]
  end

  defp check(name, url, opts, consistency, resource, subject) do
    %{
      name: name,
      licet: fn ->
        {:ok, answer} = Licet.check(Licet.Bench.Licet, resource, "view", subject, opts)
        answer == :allowed
      end,
      spicedb: fn ->
        {:ok, answer} =
          SpiceDB.check(url, object(resource), "view", subject(subject), consistency)

        answer
      end
    }
  end

  defp agree!(mode, scenario) do
    licet = scenario.licet.()
    spicedb = scenario.spicedb.()

    if licet != spicedb do
      raise "#{scenario.name} (#{mode}): Licet answered #{inspect(licet)}, SpiceDB #{inspect(spicedb)}"
    end
  end

  defp stats(suite) do
    Map.new(suite.scenarios, fn scenario ->
      s = scenario.run_time_data.statistics
      {scenario.name, %{median: s.median, p99: s.percentiles[99], ips: s.ips}}
    end)
  end

  defp print_table(results) do
    IO.puts(
      "\n| Consistency | Scenario | Parallel | Licet median | Licet p99 | Licet ips | SpiceDB median | SpiceDB p99 | SpiceDB ips |"
    )

    IO.puts("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")

    for {mode, name, parallel, %{"Licet" => l, "SpiceDB" => s}} <- results do
      IO.puts(
        "| #{mode} | #{name} | #{parallel} | #{us(l.median)} | #{us(l.p99)} | #{ips(l.ips)} | " <>
          "#{us(s.median)} | #{us(s.p99)} | #{ips(s.ips)} |"
      )
    end
  end

  defp us(nanoseconds) when nanoseconds >= 1_000_000,
    do: "#{Float.round(nanoseconds / 1_000_000, 2)} ms"

  defp us(nanoseconds), do: "#{Float.round(nanoseconds / 1_000, 1)} μs"

  defp ips(ips) when ips >= 1_000, do: "#{Float.round(ips / 1_000, 1)} K"
  defp ips(ips), do: "#{Float.round(ips, 1)}"

  defp start_licet!(relationships) do
    opts = repo_opts()
    _ = Ecto.Adapters.Postgres.storage_up(opts)
    _ = Ecto.Adapters.Postgres.storage_up(Keyword.put(opts, :database, "spicedb_bench"))
    {:ok, _} = Repo.start_link(opts)

    Repo.query!("DROP SCHEMA IF EXISTS #{@prefix} CASCADE")
    Licet.Testing.migrate!(Repo, @prefix)

    {:ok, _} =
      Licet.start_link(
        name: Licet.Bench.Licet,
        repo: Repo,
        prefix: @prefix,
        schema: {:string, @schema}
      )

    relationships
    |> Enum.chunk_every(10_000)
    |> Enum.each(fn chunk -> {:ok, _token} = Licet.import(Licet.Bench.Licet, chunk) end)
  end

  defp repo_opts do
    [
      username: System.get_env("PGUSER", "postgres"),
      password: System.get_env("PGPASSWORD", "postgres"),
      hostname: System.get_env("PGHOST", "127.0.0.1"),
      port: env_integer("PGPORT", 54_329),
      database: "licet_bench",
      pool_size: 20,
      timeout: 120_000,
      log: false
    ]
  end

  defp reachable!(url) do
    case Req.post(url <> "/v1/schema/read",
           json: %{},
           retry: false,
           headers: [{"authorization", "Bearer test"}]
         ) do
      {:ok, %{status: status}} when status in [200, 404] ->
        :ok

      _ ->
        opts = repo_opts()

        uri =
          "postgres://#{opts[:username]}:#{opts[:password]}@#{opts[:hostname]}:#{opts[:port]}/spicedb_bench"

        IO.puts("""
        SpiceDB is not reachable at #{url}. Start it on the same Postgres server:

            createdb -h #{opts[:hostname]} -p #{opts[:port]} -U #{opts[:username]} spicedb_bench
            spicedb datastore migrate head --datastore-engine postgres --datastore-conn-uri #{uri}
            spicedb serve --datastore-engine postgres --datastore-conn-uri #{uri} \\
              --http-enabled --grpc-preshared-key test
        """)

        System.halt(1)
    end
  end

  defp object(text) do
    [type, id] = String.split(text, ":", parts: 2)
    {type, id}
  end

  defp subject(text) do
    {type, id} = object(text)
    {type, id, ""}
  end

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end
end

Licet.Bench.run()
