defmodule PlaygroundWeb.Router do
  use PlaygroundWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug PlaygroundWeb.Plugs.Mode
    plug :put_root_layout, html: {PlaygroundWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", PlaygroundWeb do
    pipe_through :browser

    live "/", PlaygroundLive
  end
end
