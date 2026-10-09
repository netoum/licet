import Config

config :blog,
  ecto_repos: [Blog.Repo],
  generators: [timestamp_type: :utc_datetime]

config :blog, BlogWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: BlogWeb.ErrorJSON], layout: false],
  pubsub_server: Blog.PubSub,
  secret_key_base: String.duplicate("b", 64)

config :logger, level: :warning

import_config "#{config_env()}.exs"
