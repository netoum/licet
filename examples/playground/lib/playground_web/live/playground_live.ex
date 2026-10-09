defmodule PlaygroundWeb.PlaygroundLive do
  @moduledoc """
  Edit a schema, relationships, assertions, and expected relations, and see
  `Licet.Validate` answer on every change, like Check Watches on
  play.authzed.com.
  """
  use PlaygroundWeb, :live_view

  alias Playground.Document

  @toasts "layout-toast"

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Licet playground")
     |> assign(:mode, Map.get(session, "mode", "light"))
     |> assign(:explain_line, "")
     |> assign(:explain_output, nil)
     |> allow_upload(:yaml,
       accept: ~w(.yaml .yml),
       max_entries: 1,
       max_file_size: 1_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> load(Document.example())}
  end

  @impl true
  def handle_event("edit", %{"document" => params}, socket) do
    document = %Document{
      schema: Map.get(params, "schema", ""),
      relationships: Map.get(params, "relationships", ""),
      assertions: Map.get(params, "assertions", ""),
      validation: Map.get(params, "validation", "")
    }

    {:noreply, load(socket, document)}
  end

  def handle_event("import", _params, socket), do: {:noreply, socket}

  def handle_event("validate", _params, socket) do
    {:noreply, socket |> load(socket.assigns.document) |> toast_error()}
  end

  def handle_event("regenerate", _params, socket) do
    case Licet.Validate.expected_relations(socket.assigns.yaml) do
      {:ok, validation} ->
        document = %{socket.assigns.document | validation: String.trim_trailing(validation)}
        {:noreply, load(socket, document)}

      {:error, error} ->
        {:noreply, toast(socket, "Cannot compute expected relations", error.message)}
    end
  end

  def handle_event("reset", _params, socket) do
    {:noreply, load(socket, Document.example())}
  end

  def handle_event("explain", %{"explain" => %{"line" => line}}, socket) do
    {:noreply, explain(socket, line)}
  end

  def handle_event("file_upload_live_cancel", params, socket) do
    {:noreply, Corex.FileUploadLive.cancel_upload_from_params(socket, :yaml, params)}
  end

  defp handle_progress(:yaml, entry, socket) do
    if entry.done? do
      source =
        consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

      {:noreply, import_file(socket, entry.client_name, source)}
    else
      {:noreply, socket}
    end
  end

  defp import_file(socket, name, source) do
    case Document.from_yaml(source) do
      {:ok, document} -> socket |> load(document) |> toast_error()
      {:error, message} -> toast(socket, "Cannot import #{name}", message)
    end
  end

  defp load(socket, %Document{} = document) do
    yaml = Document.to_yaml(document)

    socket
    |> assign(:document, document)
    |> assign(:yaml, yaml)
    |> assign(:result, Playground.Result.new(yaml))
    |> reexplain()
  end

  defp reexplain(%{assigns: %{explain_line: line}} = socket)
       when is_binary(line) and line != "" do
    explain(socket, line)
  end

  defp reexplain(socket), do: socket

  defp explain(socket, line) do
    line = String.trim(line)

    output =
      cond do
        line == "" ->
          "Enter a check such as document:readme#view@user:carl"

        true ->
          case Licet.Validate.explain(socket.assigns.yaml, line) do
            {:ok, _answer, trace} -> Playground.Result.format_trace(trace)
            {:error, %Licet.Error{message: message}} -> message
          end
      end

    socket
    |> assign(:explain_line, line)
    |> assign(:explain_output, output)
  end

  defp toast_error(%{assigns: %{result: %{error: %Licet.Error{} = error}}} = socket) do
    toast(socket, "The file does not validate", error.message)
  end

  defp toast_error(socket), do: socket

  defp toast(socket, title, message) do
    Corex.Toast.create(socket, @toasts, title, message, :error, duration: 8_000)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} mode={@mode}>
      <div class="mx-auto flex w-full max-w-9xl flex-col gap-space-xl px-space-xl pb-space-xl">
        <.layout_heading class="layout-heading" subtitle_tag="p">
          <:title>Licet playground</:title>
          <:subtitle>
            A SpiceDB validation file, checked by Licet as you type. Import a file
            exported from play.authzed.com, or copy this one out.
          </:subtitle>
          <:actions>
            <.action id="validate" class="button ui-accent ui-solid" phx-click="validate">
              <.heroicon name="hero-check-badge" /> Validate
            </.action>
            <.action id="regenerate" class="button" phx-click="regenerate">
              <.heroicon name="hero-arrow-path" /> Recompute expected relations
            </.action>
            <.action id="reset" class="button ui-ghost" phx-click="reset">
              Load example
            </.action>
          </:actions>
        </.layout_heading>

        <div class="grid gap-space-xl lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
          <form
            id="document-form"
            phx-change="edit"
            class="flex w-full max-w-none min-w-0 flex-col gap-space"
          >
            <.tabs id="editors" class="tabs" value="schema">
              <:trigger value="schema">Schema</:trigger>
              <:content value="schema">
                <.editor
                  id="schema"
                  field="schema"
                  value={@document.schema}
                  rows="22"
                  label="Schema (.zed)"
                />
              </:content>
              <:trigger value="relationships">Relationships</:trigger>
              <:content value="relationships">
                <.editor
                  id="relationships"
                  field="relationships"
                  value={@document.relationships}
                  rows="22"
                  label="One relationship per line, // for comments"
                />
              </:content>
              <:trigger value="assertions">Assertions</:trigger>
              <:content value="assertions">
                <.editor
                  id="assertions"
                  field="assertions"
                  value={@document.assertions}
                  rows="22"
                  label="assertTrue and assertFalse (YAML)"
                />
              </:content>
              <:trigger value="validation">Expected relations</:trigger>
              <:content value="validation">
                <.editor
                  id="validation"
                  field="validation"
                  value={@document.validation}
                  rows="22"
                  label="resource#permission and the subjects that hold it (YAML)"
                />
              </:content>
            </.tabs>
          </form>

          <section id="results" class="flex min-w-0 flex-col gap-space-lg" aria-live="polite">
            <.result_summary result={@result} />

            <div :if={@result.watches != []} class="flex flex-col gap-space-sm">
              <h2 class="m-0 text-sm font-semibold">Check watches</h2>
              <.code
                id="watches"
                class="code"
                code={Playground.Result.format_watches(@result.watches)}
              />
            </div>

            <div :if={@result.expected != []} class="flex flex-col gap-space-sm">
              <h2 class="m-0 text-sm font-semibold">Expected relations</h2>
              <.code id="expected" class="code" code={Enum.join(@result.expected, "\n\n")} />
            </div>

            <div id="explain" class="flex flex-col gap-space-sm">
              <h2 class="m-0 text-sm font-semibold">Explain a check</h2>
              <form
                id="explain-form"
                phx-submit="explain"
                class="flex w-full max-w-none flex-col gap-space"
              >
                <.native_input
                  id="explain-line"
                  type="text"
                  name="explain[line]"
                  value={@explain_line}
                  class="native-input font-mono"
                  placeholder="document:readme#view@user:carl"
                >
                  <:label>resource#permission@subject</:label>
                </.native_input>
                <.action id="explain-submit" type="submit" class="button">
                  <.heroicon name="hero-magnifying-glass" /> Explain
                </.action>
              </form>
              <.code :if={@explain_output} id="explain-output" class="code" code={@explain_output} />
            </div>

            <div class="flex flex-col gap-space-sm">
              <h2 class="m-0 text-sm font-semibold">Import and export</h2>
              <form id="import-form" phx-change="import" class="w-full max-w-none">
                <.file_upload_live
                  id="import"
                  upload={@uploads.yaml}
                  upload_name={:yaml}
                  class="file-upload"
                >
                  <:label>Import a playground YAML file</:label>
                  <:close><.heroicon name="hero-x-mark" /></:close>
                </.file_upload_live>
              </form>
              <.clipboard
                id="export"
                class="clipboard"
                value={@yaml}
                input={false}
                trigger_aria_label="Copy YAML"
              >
                <:label>Copy the validation file</:label>
                <:copy><.heroicon name="hero-clipboard" /></:copy>
                <:copied><.heroicon name="hero-check" /></:copied>
              </.clipboard>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr(:id, :string, required: true)
  attr(:field, :string, required: true)
  attr(:value, :string, required: true)
  attr(:rows, :string, required: true)
  attr(:label, :string, required: true)

  defp editor(assigns) do
    ~H"""
    <.native_input
      id={"document-#{@id}"}
      type="textarea"
      name={"document[#{@field}]"}
      value={@value}
      rows={@rows}
      phx-debounce="300"
      class="native-input font-mono"
    >
      <:label>{@label}</:label>
    </.native_input>
    """
  end

  attr(:result, Playground.Result, required: true)

  defp result_summary(%{result: %{error: %Licet.Error{}}} = assigns) do
    ~H"""
    <div id="summary" class="flex flex-col gap-space-sm">
      <h2 class="m-0 text-sm font-semibold">The file does not validate</h2>
      <.code class="code" code={@result.error.message} />
    </div>
    """
  end

  defp result_summary(assigns) do
    ~H"""
    <div id="summary" class="flex flex-col gap-space-sm">
      <h2 class="m-0 text-sm font-semibold">
        {if Playground.Result.passed?(@result),
          do: "Every assertion and expected relation holds",
          else: "Some checks fail"}
      </h2>
    </div>
    """
  end
end
