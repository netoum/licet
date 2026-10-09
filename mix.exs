defmodule Licet.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/netoum/licet"

  def project do
    [
      app: :licet,
      name: "Licet",
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      dialyzer: dialyzer(),
      test_coverage: [
        summary: [threshold: 100],
        ignore_modules: [
          Licet.TestRepo,
          Licet.DataCase,
          Licet.FakeRepo,
          Licet.Differential,
          Licet.Conformance,
          Licet.SpiceDB,
          Licet.SlowReader,
          Licet.Reader.Licet.SlowReader
        ]
      ],
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:jason, "~> 1.4"},
      {:nimble_parsec, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.3"},
      {:yaml_elixir, "~> 2.11"},
      {:benchee, "~> 1.3", only: [:dev, :test], runtime: false},
      {:req, "~> 0.5", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :jason, :ecto, :ecto_sql, :telemetry],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end

  defp description do
    "Relationship-based authorization for Elixir, embedded in your Postgres database."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      files:
        ~w(lib mix.exs README.md CHANGELOG.md LICENSE NOTICE .formatter.exs CONTRIBUTING.md CODE_OF_CONDUCT.md guides),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "SpiceDB" => "https://authzed.com/docs/spicedb"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md": [title: "Changelog"],
        "guides/getting-started.md": [title: "Getting started"],
        "guides/modeling.md": [title: "Modeling"],
        "guides/zed.md": [title: "Schema language"],
        "guides/consistency.md": [title: "Consistency"],
        "guides/transactions.md": [title: "Transactions"],
        "guides/operations.md": [title: "Operations"],
        "guides/testing.md": [title: "Testing"],
        "guides/migrating.md": [title: "Migrating"],
        "guides/security.md": [title: "Security"],
        "guides/upgrade.md": [title: "Upgrade guide"],
        "guides/benchmarks.md": [title: "Benchmarks"],
        "guides/design.md": [title: "Design"],
        "CONTRIBUTING.md": [title: "Contributing"],
        "CODE_OF_CONDUCT.md": [title: "Code of Conduct"]
      ],
      groups_for_modules: [
        Core: [Licet, Licet.Error, Licet.Relationship, Licet.Token, Licet.Config],
        Schema: [Licet.Schema, Licet.Schema.Diff],
        Engine: [Licet.Engine, Licet.Engine.Subjects],
        Storage: [Licet.Migration, Licet.Store, Licet.GC],
        Integration: [Licet.Multi, Licet.Testing, Licet.Validate]
      ],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp aliases do
    [
      "test.ci": ["test --cover"]
    ]
  end
end
