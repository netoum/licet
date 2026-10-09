import Config

port =
  case System.get_env("PGPORT") do
    nil -> 54_329
    value -> String.to_integer(value)
  end

config :blog, :licet_start, false

config :blog, Blog.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "127.0.0.1"),
  port: port,
  database: System.get_env("PGDATABASE", "blog_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :blog, BlogWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: 4002], server: false
