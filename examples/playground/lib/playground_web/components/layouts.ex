defmodule PlaygroundWeb.Layouts do
  @moduledoc """
  The page frame: header with the mode toggle, the toast group, and the footer.
  """
  use PlaygroundWeb, :html

  embed_templates("layouts/*")

  @links [
    %{label: "SpiceDB playground", to: "https://play.authzed.com"},
    %{
      label: "Validation files",
      to: "https://authzed.com/docs/spicedb/modeling/validation-testing-debugging"
    },
    %{label: "Corex", to: "https://hexdocs.pm/corex"}
  ]

  @doc """
  Renders the app layout.

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:mode, :string, default: "light", doc: "the current mode (dark or light)")
  slot(:inner_block, required: true)

  def app(assigns) do
    assigns = assign(assigns, :links, @links)

    ~H"""
    <header class="sticky top-0 z-20 flex h-size-lg items-center border-b border-border bg-surface">
      <div class="mx-auto flex h-size-lg w-full max-w-9xl items-center justify-between gap-space-lg px-space-xl">
        <.navigate to={~p"/"} class="link ui-nav ui-brand ui-size-xl font-semibold">
          Licet
        </.navigate>
        <div class="flex items-center gap-space-lg">
          <nav class="hidden items-center gap-space-lg md:flex" aria-label="Links">
            <.navigate :for={link <- @links} class="link ui-nav ui-size-sm" external to={link.to}>
              {link.label} <.heroicon name="hero-arrow-top-right-on-square" />
            </.navigate>
          </nav>
          <.mode_toggle id="mode-switcher" mode={@mode} />
        </div>
      </div>
    </header>

    <main class="relative flex w-full min-w-0 flex-1 flex-col pt-space-xl">
      {render_slot(@inner_block)}
    </main>

    <footer class="flex items-center border-t border-border bg-surface">
      <p class="mx-auto m-0 w-full max-w-9xl px-space-xl py-space-lg text-sm text-ink-muted">
        Runs locally. Checks are answered by Licet's engine on an in-memory copy of the relationships.
      </p>
    </footer>

    <.toast_group id="layout-toast" class="toast" flash={@flash}>
      <:loading><.heroicon name="hero-arrow-path" /></:loading>
      <:close><.heroicon name="hero-x-mark" /></:close>
    </.toast_group>
    <.toast_client_error
      toast_group_id="layout-toast"
      title="We lost the connection"
      description="We're trying to reconnect you..."
      type={:error}
      duration={:infinity}
    />
    """
  end

  @doc """
  Dark and light mode toggle.
  """
  attr(:id, :string, default: "mode-switcher")
  attr(:class, :string, default: nil)
  attr(:mode, :string, default: "light", values: ["light", "dark"])

  def mode_toggle(assigns) do
    ~H"""
    <.toggle
      id={@id}
      class={["toggle ui-ghost ui-size-sm ui-trigger--circle", @class]}
      data-toggle-dual-label
      pressed={@mode == "dark"}
      on_pressed_change_client="phx:set-mode"
    >
      <span>
        <.heroicon name="hero-moon" />
        <span class="sr-only">Dark mode</span>
      </span>
      <span data-pressed>
        <.heroicon name="hero-sun" />
        <span class="sr-only">Light mode</span>
      </span>
    </.toggle>
    """
  end
end
