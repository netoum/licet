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

  test "the author can fetch and list the post; another user cannot" do
    assert {:ok, %{post: post}} = Blog.Posts.create_post("ada", %{title: "Hello"})

    assert {:ok, ^post} = Blog.Posts.fetch_post("ada", post.id)
    assert {:error, :not_found} = Blog.Posts.fetch_post("bob", post.id)

    assert {:ok, [^post]} = Blog.Posts.list_posts("ada")
    assert {:ok, []} = Blog.Posts.list_posts("bob")
  end

  test "a viewer relationship makes the post visible to that user" do
    assert {:ok, %{post: post}} = Blog.Posts.create_post("ada", %{title: "Shared"})

    assert {:ok, _token} =
             Licet.write(Blog.Licet, [{:create, "post:#{post.id}#viewer@user:bob"}])

    assert {:ok, ^post} = Blog.Posts.fetch_post("bob", post.id)
    assert {:ok, [^post]} = Blog.Posts.list_posts("bob")
  end
end
