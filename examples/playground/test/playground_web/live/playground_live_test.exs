defmodule PlaygroundWeb.PlaygroundLiveTest do
  use PlaygroundWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Playground.Document

  test "the example passes every check watch", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#summary", "Every assertion and expected relation holds")
    assert has_element?(view, "#watches", "✓ document:readme#view@user:carl")
    refute has_element?(view, "#expected")
  end

  test "an edit re-runs the checks", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    example = Document.example()

    relationships = String.replace(example.relationships, "group:platform#member@user:carl", "")

    render_change(view, "edit", %{
      "document" => Map.from_struct(%{example | relationships: relationships})
    })

    assert has_element?(view, "#summary", "Some checks fail")

    assert view |> element("#watches") |> render() =~
             "✗ document:readme#view@user:carl  expected allowed, got denied"

    assert has_element?(view, "#expected", "missing expected subject `user:carl`")
  end

  test "recomputing expected relations makes them hold again", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    example = Document.example()

    render_change(view, "edit", %{
      "document" => Map.from_struct(%{example | validation: "document:readme#view: []"})
    })

    assert has_element?(view, "#expected")

    view |> element("#regenerate") |> render_click()

    refute has_element?(view, "#expected")

    assert view |> element("#document-validation-input") |> render() =~
             "[user:carl] is &lt;group:platform#member&gt;"
  end

  test "a rejected schema shows the error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_change(view, "edit", %{
      "document" => %{"schema" => "caveat ok(a int) { a == 1 }", "relationships" => ""}
    })

    assert has_element?(view, "#summary", "caveats are not supported")
    view |> element("#validate") |> render_click()
    view |> element("#regenerate") |> render_click()
    view |> element("#reset") |> render_click()
    assert has_element?(view, "#summary", "Every assertion and expected relation holds")
  end

  test "imports a playground file", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    source = """
    schema: |-
      definition user {}
      definition document {
        relation viewer: user
        permission view = viewer
      }
    relationships: |-
      document:1#viewer@user:ada
    assertions:
      assertTrue:
        - document:1#view@user:ada
    """

    upload =
      file_input(view, "#import-form", :yaml, [
        %{name: "ada.yaml", content: source, type: "application/yaml"}
      ])

    render_upload(upload, "ada.yaml")

    assert has_element?(view, "#watches", "✓ document:1#view@user:ada")
    assert render(view) =~ "document:1#viewer@user:ada"

    broken =
      file_input(view, "#import-form", :yaml, [
        %{name: "broken.yaml", content: "- 1", type: "application/yaml"}
      ])

    render_upload(broken, "broken.yaml")
    assert has_element?(view, "#watches", "✓ document:1#view@user:ada")
  end
end
