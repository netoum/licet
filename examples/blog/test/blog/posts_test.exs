defmodule Blog.PostsTest do
  use ExUnit.Case, async: false

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Blog.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    start_supervised!(
      {Licet,
       name: Blog.Licet,
       repo: Blog.Repo,
       prefix: "licet",
       schema: {:file, Application.app_dir(:blog, "priv/licet/schema.zed")},
       gc_interval: false}
    )

    :ok
  end

  test "the author can view the post created in the same transaction" do
    assert {:ok, %{post: post, grant: "v1." <> _}} =
             Blog.Posts.create_post("ada", %{title: "Hello"})

    assert {:ok, :allowed} = Licet.check(Blog.Licet, "post:#{post.id}", "view", "user:ada")
    assert {:ok, :denied} = Licet.check(Blog.Licet, "post:#{post.id}", "view", "user:bob")
  end
end
