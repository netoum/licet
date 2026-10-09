# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :playground, generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :playground, PlaygroundWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PlaygroundWeb.ErrorHTML, json: PlaygroundWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Playground.PubSub,
  live_view: [signing_salt: "lVH6aGO5"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  playground: [
    args:
      ~w(js/app.js --bundle --format=esm --splitting --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      "NODE_PATH" => Enum.join([Path.expand("../deps", __DIR__), Mix.Project.build_path()], ":")
    }
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  playground: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{
      "NODE_PATH" => Enum.join([Path.expand("../deps", __DIR__), Mix.Project.build_path()], ":")
    }
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :mime, :types, %{"application/yaml" => ["yaml", "yml"]}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
config :corex,
  generators: [
    layout: [mode: true]
  ]

config :corex_design,
  output: "assets/corex",
  default_theme: :neo,
  default_mode: :light,
  themes: [:neo],
  modes: [:light, :dark],
  scales: [],
  components: [
    :toast,
    :"layout-heading",
    :typo,
    :icon,
    :link,
    :button,
    :dialog,
    :scrollbar,
    :checkbox,
    :"native-input",
    :select,
    :toggle,
    :badge,
    :menu,
    :accordion,
    :code,
    :clipboard,
    :tabs,
    :"file-upload"
  ],
  semantics: [:accent, :brand, :alert]

import_config "#{config_env()}.exs"
