defmodule Licet.MixProject do
  use Mix.Project

  @version "0.0.1"
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
          Licet.CountingReader,
          Licet.Reader.Licet.CountingReader
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
    "Fine-grained, relationship-based authorization for Elixir, using SpiceDB's schema language and stored in your own Postgres database."
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
        "README.md": [title: "Overview"],
        "guides/getting-started.md": [title: "Getting started"],
        "guides/concepts.md": [title: "Concepts"],
        "guides/cheatsheet.cheatmd": [title: "Cheatsheet"],
        "guides/modeling.md": [title: "Modeling permissions"],
        "guides/zed.md": [title: "Schema language"],
        "guides/phoenix.md": [title: "Phoenix integration"],
        "guides/consistency.md": [title: "Consistency"],
        "guides/transactions.md": [title: "Transactions"],
        "guides/testing.md": [title: "Testing"],
        "guides/operations.md": [title: "Operations"],
        "guides/telemetry.md": [title: "Telemetry"],
        "guides/security.md": [title: "Security"],
        "guides/migrating.md": [title: "Migrating to or from SpiceDB"],
        "guides/limitations.md": [title: "Limitations"],
        "guides/internals/design.md": [title: "Design"],
        "guides/internals/conformance.md": [title: "Conformance testing"],
        "guides/internals/benchmarks.md": [title: "Benchmarks"],
        "CHANGELOG.md": [title: "Changelog"],
        "CONTRIBUTING.md": [title: "Contributing"],
        "CODE_OF_CONDUCT.md": [title: "Code of Conduct"]
      ],
      groups_for_extras: [
        Introduction: [
          "README.md",
          "guides/getting-started.md",
          "guides/concepts.md",
          "guides/cheatsheet.cheatmd"
        ],
        Guides: [
          "guides/modeling.md",
          "guides/zed.md",
          "guides/phoenix.md",
          "guides/consistency.md",
          "guides/transactions.md",
          "guides/testing.md"
        ],
        Operations: [
          "guides/operations.md",
          "guides/telemetry.md",
          "guides/security.md",
          "guides/migrating.md",
          "guides/limitations.md"
        ],
        Internals: ~r"guides/internals/",
        Project: ["CHANGELOG.md", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md"]
      ],
      groups_for_modules: [
        Core: [Licet, Licet.Error, Licet.Relationship],
        Schema: [Licet.Schema],
        "Testing and tooling": [
          Licet.Multi,
          Licet.Testing,
          Licet.Validate,
          Mix.Tasks.Licet.Gen.Migration,
          Mix.Tasks.Licet.Validate
        ],
        Storage: [Licet.Migration, Licet.GC]
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
