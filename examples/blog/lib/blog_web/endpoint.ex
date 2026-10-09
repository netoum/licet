defmodule BlogWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :blog

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug BlogWeb.Router
end
