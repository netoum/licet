defmodule BlogWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BlogWeb do
    pipe_through :api
    get "/posts", PostController, :index
    get "/posts/:id", PostController, :show
    post "/posts", PostController, :create
  end
end
