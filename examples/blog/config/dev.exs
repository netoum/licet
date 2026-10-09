import Config

config :blog, Blog.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  port: 54_329,
  database: "blog_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :blog, BlogWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: 4000]
