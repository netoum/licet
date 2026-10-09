defmodule BlogWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BlogWeb do
    pipe_through :api
    post "/posts", PostController, :create
  end
end
