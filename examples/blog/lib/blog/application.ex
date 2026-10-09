defmodule Blog.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Blog.Repo,
        {Phoenix.PubSub, name: Blog.PubSub},
        BlogWeb.Endpoint
      ] ++ licet()

    Supervisor.start_link(children, strategy: :one_for_one, name: Blog.Supervisor)
  end

  defp licet do
    if Application.get_env(:blog, :licet_start, true) do
      [
        {Licet,
         name: Blog.Licet,
         repo: Blog.Repo,
         prefix: "licet",
         schema: {:file, Application.app_dir(:blog, "priv/licet/schema.zed")},
         gc_interval: false}
      ]
    else
      []
    end
  end
end
