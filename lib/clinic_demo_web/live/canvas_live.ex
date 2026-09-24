defmodule ClinicDemoWeb.CanvasLive do
  @moduledoc """
  The dev-only `/canvas` surface: the application's domains, resources and
  relationships as a navigable object graph, with a server-resolved
  naked-object inspector on selection.

  The graph itself is rendered by the `<ash-canvas-graph>` Lit element
  (driver lane, Cytoscape under the hood) through the `AshCanvas` hook. This
  LiveView owns the two server sides of that contract:

    * on connected mount it builds the graph with
      `AshA2ui.Canvas.build_graph/1` over `ClinicDemo.Canvas.Registry`
      and pushes it once as `"canvas:graph"` — structural nodes only. No
      record is ever a node, and no read happens at all: the graph is
      declared metadata, not a query (`A2UI-103/AC-4`).
    * `handle_event("canvas:select", …)` is the *only* client event that
      exists. It resolves one opaque ref through
      `AshA2ui.Canvas.resolve/2` under the signed-in actor and
      re-renders the inspector. There is no event that can request records:
      a record enters the picture only when someone resolves a record ref,
      which is an authorized read, and a ref the actor cannot read is the
      same fail-closed `{:error, :unknown_object}` as garbage.

  The inspector is server-rendered HEEx — deliberately not an A2UI surface —
  because its job is to *show what the library knows* (provenance,
  capabilities, projections) rather than to be one of the projections it
  describes. Where a resource has a declared app surface, the browse
  projection becomes a link to it via `ClinicDemoWeb.A2ui.Surfaces`.
  """

  use ClinicDemoWeb, :live_view

  alias AshA2ui.Canvas
  alias AshA2ui.Canvas.Object
  alias ClinicDemo.Canvas.Registry
  alias ClinicDemoWeb.A2ui.Host
  alias ClinicDemoWeb.A2ui.Surfaces

  @impl true
  def mount(_params, _session, socket) do
    graph = Canvas.build_graph(Registry)

    socket =
      assign(socket,
        revision: graph.revision,
        node_count: map_size(graph.nodes),
        relationship_count: Enum.count(graph.edges, &(&1.kind == :relationship)),
        selected: nil,
        selection_error: nil,
        presentation: nil,
        refresh_scheduled?: false
      )

    if connected?(socket) do
      {:ok, push_event(socket, "canvas:graph", graph_payload(graph))}
    else
      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <header class="space-y-1">
        <h1 class="text-2xl font-semibold">Canvas</h1>
        <p class="text-sm opacity-70">
          The application's domains, resources and relationships as one
          object graph. Dev-only.
          Selection resolves a naked object server-side; no records are ever
          part of the graph.
        </p>
        <p class="text-xs">
          Revision <code class="font-mono">{String.slice(@revision, 0, 19)}…</code>
          · {@node_count} nodes · {@relationship_count} relationship edges
        </p>
      </header>

      <%!--
        The shell is a two-row CSS grid: graph pane, splitter, inspector
        pane. The splitter is the CanvasSplitter hook — pointer drag
        rewrites the first grid track (persisted to localStorage under the
        shell's layout key, reset on double-click or Enter), and collapse
        buttons flip panes with JS.toggle + aria-expanded/aria-hidden.

        Zero-jank guards: collapsed panes stay MOUNTED — JS.toggle only
        flips display, and the phx-update="ignore" graph container below is
        never removed from the DOM, so the Lit element and its Cytoscape
        instance survive collapse/expand; the hook resizes the graph's
        buffers once per drag-end (never per pointer-move); the divider
        carries no transitions, so drags are motion-free (and the
        stylesheet's reduced-motion rule stands guard regardless).
      --%>
      <div class="flex items-center justify-end gap-2">
        <button
          id="canvas-toggle-graph"
          type="button"
          aria-expanded="true"
          aria-controls="canvas-pane-graph"
          phx-click={
            JS.toggle(to: "#canvas-pane-graph")
            |> JS.toggle_attribute({"aria-expanded", "true", "false"},
              to: "#canvas-toggle-graph"
            )
            |> JS.toggle_attribute({"aria-hidden", "false", "true"},
              to: "#canvas-pane-graph"
            )
          }
          class="inline-flex h-8 items-center gap-1.5 rounded-base border-2 border-border bg-secondary-background px-2.5 text-xs font-base text-foreground shadow-shadow transition-all hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press"
        >
          <.icon name="hero-view-columns" class="size-4" /> Graph
        </button>
        <button
          id="canvas-toggle-inspector"
          type="button"
          aria-expanded="true"
          aria-controls="canvas-pane-inspector"
          phx-click={
            JS.toggle(to: "#canvas-pane-inspector")
            |> JS.toggle_attribute({"aria-expanded", "true", "false"},
              to: "#canvas-toggle-inspector"
            )
            |> JS.toggle_attribute({"aria-hidden", "false", "true"},
              to: "#canvas-pane-inspector"
            )
          }
          class="inline-flex h-8 items-center gap-1.5 rounded-base border-2 border-border bg-secondary-background px-2.5 text-xs font-base text-foreground shadow-shadow transition-all hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press"
        >
          <.icon name="hero-information-circle" class="size-4" /> Inspector
        </button>
      </div>

      <div
        id="canvas-shell"
        class="canvas-shell grid"
        style="grid-template-rows: minmax(0, 72vh) auto auto;"
      >
        <section
          id="canvas-pane-graph"
          class="min-h-0 min-w-0"
          aria-label="Canvas graph pane"
          aria-hidden="false"
        >
          <div
            id="canvas-graph"
            phx-hook="AshCanvas"
            phx-update="ignore"
            aria-label="Canvas object graph"
            class="h-full min-h-[18rem]"
          >
            <%!-- The Lit element owns this subtree (phx-update="ignore"). --%>
          </div>
        </section>

        <div
          id="canvas-splitter"
          phx-hook="CanvasSplitter"
          role="separator"
          aria-orientation="vertical"
          tabindex="0"
          aria-label="Resize the graph pane (drag, arrow keys; Enter or double-click resets)"
          aria-valuemin="10"
          aria-valuemax="90"
          aria-valuenow="72"
          aria-valuetext="graph pane height"
          data-target="#canvas-shell"
          data-pane="#canvas-pane-graph"
          data-layout-key="canvas-shell"
          data-min="160"
          class="canvas-splitter"
        >
          <span class="canvas-splitter-grip" aria-hidden="true"></span>
        </div>

        <section
          id="canvas-pane-inspector"
          class="space-y-4"
          aria-label="Canvas inspector pane"
          aria-hidden="false"
        >
          <%!--
        The container is rendered ALWAYS and hidden with a class, never
        removed. `Host.present/3` delivers the surface by pushing an event to
        the `AshA2ui` hook, and a hook that does not exist yet receives
        nothing -- so rendering this conditionally means the first selection
        pushes into a void and the panel stays blank. Same reason AgentLive
        keeps its container mounted.
      --%>
          <section
            class={["space-y-2", if(!@presentation, do: "hidden")]}
            aria-label="Surface for the selected resource"
          >
            {AshA2ui.LiveRenderer.surface_container(assigns)}
          </section>

          <div id="canvas-inspector" class="space-y-3">
            <%= if @selection_error == :unknown_object do %>
              <div
                class="relative grid w-full gap-2 rounded-base border-2 border-border bg-background px-4 py-3 text-sm text-foreground shadow-shadow"
                role="status"
              >
                <.icon name="hero-exclamation-triangle" class="size-5" />
                <span>Unknown object — the reference does not name anything this canvas exposes.</span>
              </div>
            <% end %>

            <%= if @selected do %>
              <.inspector object={@selected} destinations={destinations_for(@selected)} />
            <% else %>
              <.empty_state icon="hero-cursor-arrow-rays">
                Select a node in the graph to inspect it.
              </.empty_state>
            <% end %>
          </div>
        </section>
      </div>
    </div>
    """
  end

  @doc false
  # The inspector panel: label + kind badge, provenance display names,
  # capabilities, projections, and a link per projection that has somewhere to
  # go. A projection badge with no destination is the object model describing a
  # capability the application does not actually offer, so the two are rendered
  # from the same list rather than side by side.
  attr :object, Object, required: true
  attr :destinations, :list, default: []

  def inspector(assigns) do
    ~H"""
    <section class="flex flex-col gap-4 rounded-base border-2 border-border bg-secondary-background px-4 py-4 font-base text-foreground shadow-lift">
      <div class="flex flex-col gap-4">
        <div class="flex items-center gap-3">
          <.badge tone="cyan" class="font-mono">{@object.ref.kind}</.badge>
          <h2 class="text-lg font-heading">{@object.label}</h2>
          <code class="font-mono text-xs opacity-60">{@object.ref.id}</code>
        </div>

        <div>
          <h3 class="text-xs font-heading uppercase opacity-60">Provenance</h3>
          <ul class="text-sm">
            <li :for={{role, module} <- provenance_rows(@object)}>
              <span class="opacity-60">{role}:</span>
              <code class="font-mono">{display_name(module)}</code>
            </li>
          </ul>
        </div>

        <div>
          <h3 class="text-xs font-heading uppercase opacity-60">Capabilities</h3>
          <ul class="divide-y divide-border text-sm">
            <li
              :for={capability <- @object.capabilities}
              class="flex flex-wrap items-center gap-2 py-1"
            >
              <span class="font-medium">{capability.label}</span>
              <.badge tone="neutral">{capability.consequence}</.badge>
              <.badge :if={capability.confirmation == :required} tone="orange">
                confirmation required
              </.badge>
              <.badge
                tone={if capability.authorized?, do: "green"}
                class={(!capability.authorized? && "opacity-60") || nil}
              >
                {if capability.authorized?, do: "authorized", else: "not authorized"}
              </.badge>
            </li>
          </ul>
        </div>

        <div>
          <h3 class="text-xs font-heading uppercase opacity-60">Projections</h3>
          <div class="flex flex-wrap gap-2">
            <.badge :for={projection <- @object.projections} tone="neutral" class="font-mono">
              {projection}
            </.badge>
          </div>
          <div class="mt-3 flex flex-wrap gap-2">
            <.link
              :for={destination <- @destinations}
              navigate={destination.path}
              class="inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-main px-3 text-sm font-base text-main-foreground shadow-shadow ring-offset-white transition-all focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-black focus-visible:ring-offset-2 disabled:pointer-events-none disabled:opacity-50 hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4" />
              {destination.label}
            </.link>
          </div>
        </div>
      </div>
    </section>
    """
  end

  @impl true
  def handle_event("canvas:select", %{"ref" => ref}, socket) when is_binary(ref) do
    actor = socket.assigns[:a2ui_actor]

    case select(ref, actor) do
      {:ok, object} ->
        socket =
          socket
          |> assign(selected: object, selection_error: nil)
          |> show_surface(surface_for(object), actor)

        {:noreply, socket}

      {:error, :unknown_object} ->
        socket =
          socket
          |> assign(selected: nil, selection_error: :unknown_object)
          |> show_surface(nil, actor)

        {:noreply, socket}
    end
  end

  def handle_event("canvas:select", _malformed, socket) do
    {:noreply, assign(socket, selected: nil, selection_error: :unknown_object)}
  end

  # The client interacted with the rendered surface. Routed through `Host`
  # rather than into an Ash action directly: the handler is what enforces the
  # row-action allowlist, `visible_when`, and the error contract that puts
  # validation messages on the reserved `/errors/<field>` paths.
  def handle_event("a2ui:action", envelope, %{assigns: %{presentation: nil}} = socket) do
    # Nothing is being shown, so there is nothing this envelope can refer to.
    # Rebuilding a surface from something the client echoed back is the
    # tamper-proofing hole the server-held presentation exists to close.
    _ = envelope
    {:noreply, socket}
  end

  def handle_event("a2ui:action", envelope, socket) do
    actor = socket.assigns[:a2ui_actor]

    {socket, presentation} =
      Host.handle_action(socket, socket.assigns.presentation, envelope, actor: actor)

    {:noreply, assign(socket, :presentation, presentation)}
  end

  @impl true
  def handle_info({:ash_a2ui_host, :refresh}, %{assigns: %{presentation: nil}} = socket) do
    {:noreply, assign(socket, :refresh_scheduled?, false)}
  end

  def handle_info({:ash_a2ui_host, :refresh}, socket) do
    actor = socket.assigns[:a2ui_actor]

    {socket, presentation} =
      Host.refresh(socket, socket.assigns.presentation, actor: actor)

    {:noreply,
     socket
     |> assign(:presentation, presentation)
     |> assign(:refresh_scheduled?, false)}
  end

  # Anything else while a surface is subscribed is a notification on one of its
  # topics. Ash's PubSub notifier can send a %Notification{}, a
  # %Phoenix.Socket.Broadcast{} or a bare map depending on `broadcast_type`, so
  # this matches on none of them and coalesces whatever arrives.
  def handle_info(_message, %{assigns: %{presentation: nil}} = socket), do: {:noreply, socket}

  def handle_info(_message, socket) do
    case Host.schedule_refresh(socket.assigns.refresh_scheduled?) do
      :scheduled -> {:noreply, assign(socket, :refresh_scheduled?, true)}
      :already_scheduled -> {:noreply, socket}
    end
  end

  # Selecting a resource that publishes a surface renders that surface, live,
  # under the graph -- the same screen the shared host seam serves, and
  # filtered by the selected actor's own policies.
  #
  # The previous selection's subscription is dropped first. Without it, walking
  # the graph leaves the LiveView subscribed to every surface it passed through,
  # and a write to any of them refreshes one nobody is looking at.
  defp show_surface(socket, nil, _actor) do
    Host.dismiss(socket.assigns.presentation)
    assign(socket, :presentation, nil)
  end

  defp show_surface(socket, surface, actor) do
    Host.dismiss(socket.assigns.presentation)

    {socket, presentation} =
      Host.present(socket, Host.declared(surface), actor: actor)

    assign(socket, :presentation, presentation)
  end

  @doc false
  # The selection seam, separate from the socket so the fail-closed contract
  # is testable without a route: exactly the library's resolve, with the
  # signed-in actor — and exactly its fail-closed error.
  @spec select(String.t() | term, term) ::
          {:ok, Object.t()} | {:error, :unknown_object}
  def select(ref, actor) do
    Canvas.resolve(ref, registry: Registry, actor: actor)
  end

  @doc false
  # The wire form of a built graph (the contract's `canvas:graph` payload):
  # plain JSON-shaped maps, structural nodes only.
  @spec graph_payload(AshA2ui.Canvas.Graph.t()) :: %{
          String.t() => String.t() | [map()]
        }
  def graph_payload(graph) do
    %{
      "revision" => graph.revision,
      "nodes" =>
        graph.nodes
        |> Map.values()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(fn node ->
          %{
            "id" => node.id,
            "kind" => to_string(node.kind),
            "label" => node.label,
            "metadata" => node.metadata
          }
        end),
      "edges" =>
        graph.edges
        |> Enum.sort_by(&{&1.from, &1.to, &1.kind, &1.name})
        |> Enum.map(fn edge ->
          %{
            "kind" => to_string(edge.kind),
            "from" => edge.from,
            "to" => edge.to,
            "name" => edge.name && to_string(edge.name)
          }
        end)
    }
  end

  # --- inspector helpers -------------------------------------------------------

  defp provenance_rows(%Object{provenance: provenance}) do
    provenance
    |> Enum.sort_by(fn {role, _module} -> role end)
    |> Enum.map(fn {role, module} -> {Atom.to_string(role), module} end)
  end

  defp display_name(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> String.replace("_", " ")
  end

  defp display_name(other), do: inspect(other)

  # The declared A2UI surface for a resolved resource, when one exists —
  # what turns the browse projection into a real link.
  # Routes this application serves for a resource that has no A2UI surface. The
  # process layer is built this way on purpose -- a BPMN diagram is bpmn-js and
  # a task list is an indexed candidate query, neither of which is a derived
  # table -- so without this the canvas showed those nodes as having nowhere to
  # go while the application had a page for each of them all along.
  @routes %{
    ClinicDemo.Visits.HumanTask => %{browse: {"Worklist", "/worklist"}},
    ClinicDemo.Visits.Token => %{browse: {"Visits board", "/visits"}},
    ClinicDemo.Visits.ProcessEvent => %{browse: {"Visits board", "/visits"}}
  }

  # `:diagram` resolves to the same catalogue as `:browse` for a process or
  # decision table, because that catalogue *is* where its diagram is opened -- the
  # designer needs a key, and picking one is what the catalogue is for. Labelled by the
  # projection rather than the route so the inspector says which claim the link
  # is honouring.
  @diagram_labels %{
    ClinicDemo.Visits.Process => {"Draw a process", "/processes"},
    ClinicDemo.Decisions.DecisionTable => {"Draw a decision", "/decisions"}
  }

  @doc false
  # One destination per projection the object claims and this application can
  # actually open. A projection with no destination renders as a badge and
  # nothing else, which is the honest depiction of a claim nothing serves.
  def destinations_for(
        %Object{ref: %{kind: :resource}, provenance: %{resource: resource}} = object
      ) do
    Enum.flat_map(object.projections, fn projection ->
      case destination(projection, resource) do
        nil -> []
        {label, path} -> [%{projection: projection, label: label, path: path}]
      end
    end)
  end

  def destinations_for(_other_object), do: []

  defp destination(:browse, resource) do
    case a2ui_surface(resource) do
      %{label: label, path: path} -> {"Browse in #{label}", path}
      nil -> get_in(@routes, [resource, :browse])
    end
  end

  defp destination(:diagram, resource), do: Map.get(@diagram_labels, resource)
  defp destination(_projection, _resource), do: nil

  # The A2UI surface for a selected object, which `show_surface/3` embeds in the
  # canvas. Distinct from `destinations_for/1`: that answers "where can a person
  # go from here", this answers "is there a derived surface to render in place".
  defp surface_for(%Object{ref: %{kind: :resource}, provenance: %{resource: resource}}) do
    a2ui_surface(resource)
  end

  defp surface_for(_other_object), do: nil

  defp a2ui_surface(resource) do
    Enum.find(Surfaces.all(), fn surface ->
      AshA2ui.Info.resource!(surface.ui) == resource
    end)
  rescue
    _not_an_a2ui_module -> nil
  end
end
