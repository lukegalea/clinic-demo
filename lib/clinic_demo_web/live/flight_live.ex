defmodule ClinicDemoWeb.FlightLive do
  @moduledoc """
  The flight view: every live visit on the process diagram, in real time.

  Built on `AshBpmn.FlightView`'s documented recipe:

    * `mermaid/2` renders the published `appointment_visit` definition once —
      the definition is immutable, so the diagram never re-renders. The client
      draws it (the `FlightDiagram` hook + the `flight_view.js` entry, which
      keep the multi-megabyte mermaid bundle off every other page, the same
      split the operator hub's `operator_diagram.js` makes).
    * `token_positions/2` answers where everything is. Its subject passthrough
      (`subject_type`/`subject_id`) is resolved into the real records here —
      one batched query per load, the same shape
      `ClinicDemo.Visits.Calculations.SubjectLabel` uses — and rendered as
      patient avatar chips: initials in the nav's PresenceBar vocabulary,
      status styling in the bpmn viewer's marker vocabulary (waiting dashed,
      executing pulsing), and a deep-link to the visit's day on /day.
    * The engine broadcasts every token transition on the definition topic;
      a broadcast is a hint, the query is the truth, so each one re-fetches
      `token_positions/2` and pushes the fresh markers to the hook — the
      markers move without a LiveView re-render. With no PubSub configured
      the documented polling fallback runs instead (and nothing else in the
      view changes).

  The avatars' click target is the one per-appointment surface the demo
  already has: /day with a `?date=` deep-link selects the visit's day and
  opens the day's list; the read-only detail sheet is one click away from
  there.
  """

  use ClinicDemoWeb, :live_view

  require Ash.Query

  alias AshA2ui.PresenceBar
  alias ClinicDemo.Rules
  alias ClinicDemo.Scheduling.Appointment
  alias ClinicDemo.Visits
  alias ClinicDemoWeb.A2ui.SurfaceChrome

  @surface_id "clinic_flight"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(definition: nil, mermaid: nil, diagram_error: nil, markers: [])
      |> load_definition()

    if connected?(socket) and socket.assigns.definition do
      topic = AshBpmn.FlightView.definition_topic(socket.assigns.definition.id)

      case AshBpmn.FlightView.subscribe(topic) do
        :ok ->
          :ok

        # No PubSub configured or not running: the documented fallback is
        # polling token_positions/2 on an interval.
        {:error, _} ->
          Process.send_after(self(), :refresh_positions, 5_000)
      end
    end

    {:ok, SurfaceChrome.mount_presence(socket, @surface_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-6">
      <header>
        <h1 class="text-2xl font-display">Flight view</h1>
        <p class="text-foreground/70">
          Every visit, live — the appointment_visit process with one avatar per token, moving as visits advance.
        </p>
      </header>

      <%= if is_nil(@definition) do %>
        <div class="rounded-base border-2 border-border bg-secondary-background px-4 py-3 text-sm">
          No published process yet — the flight view draws the latest published
          appointment_visit definition, and the clinic has none. Run
          <code class="font-mono">mix seed</code>
          to publish one.
        </div>
      <% else %>
        <section aria-label="Live process diagram">
          <div
            id="flight-diagram"
            class="relative w-full overflow-hidden rounded-base border-2 border-border bg-secondary-background p-4"
            phx-hook="FlightDiagram"
            data-mermaid={@mermaid}
            data-positions={Jason.encode!(@markers)}
          >
            <div data-flight-canvas class="w-full [&_svg]:mx-auto [&_svg]:h-auto [&_svg]:max-w-full">
            </div>
            <div data-flight-markers class="pointer-events-none absolute inset-0"></div>
          </div>

          <%!-- The no-JS (and pre-mermaid) fallback: the same markers, as text. --%>
          <ul class="mt-3 flex flex-wrap gap-2">
            <li :for={marker <- @markers} key={marker.token_id}>
              <.link
                navigate={marker.href}
                class="inline-flex items-center gap-2 rounded-base border-2 border-border bg-main px-2.5 py-1 text-xs font-base text-main-foreground shadow-shadow hover:shadow-lift"
              >
                <span class="inline-flex size-5 items-center justify-center rounded-full border-2 border-border bg-secondary-background text-[9px] font-bold text-foreground">
                  {marker.initials}
                </span>
                {marker.label} — {marker.node_name} ({marker.status})
              </.link>
            </li>
            <li :if={@markers == []} class="text-sm text-foreground/60">
              Nothing in flight right now — book a visit and watch it walk the diagram.
            </li>
          </ul>
        </section>
      <% end %>
    </div>
    """
  end

  # --- data ------------------------------------------------------------------

  defp load_definition(socket) do
    # Latest published pins the flight view: instances run on the version
    # they started with, but the flight view is the operator's "what the
    # process looks like now" — the newest published drawing wins.
    case Visits.latest_published_process(Rules.process_key()) do
      {:ok, [definition | _]} ->
        case AshBpmn.FlightView.mermaid(definition) do
          {:ok, mermaid} ->
            socket
            |> assign(definition: definition, mermaid: mermaid)
            |> reload_positions()

          {:error, :no_graph} ->
            assign(socket, diagram_error: :no_graph)
        end

      _none ->
        socket
    end
  end

  defp reload_positions(socket) do
    case socket.assigns.definition do
      nil ->
        socket

      definition ->
        markers =
          AshBpmn.FlightView.token_positions!(ClinicDemo.Visits, definition: definition)
          |> markers()

        assign(socket, :markers, markers)
    end
  end

  # One pass over the positions: the engine hands back subject join keys, the
  # host resolves them into records with a single filtered read (the same
  # batch shape SubjectLabel uses), then renders each token as an avatar.
  defp markers(positions) do
    appointments =
      positions
      |> Enum.map(& &1.subject_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> case do
        [] ->
          %{}

        ids ->
          Appointment
          |> Ash.Query.filter(id in ^ids)
          |> Ash.Query.load(:patient)
          |> Ash.read!(authorize?: false)
          |> Map.new(&{&1.id, &1})
      end

    Enum.map(positions, fn position ->
      appointment = appointments[position.subject_id]

      label =
        case appointment do
          %{patient: %{name: name}, reason: reason} -> "#{name} — #{reason}"
          _ -> "Visit #{String.slice(position.instance_id, 0..7)}"
        end

      %{
        token_id: position.token_id,
        node_id: position.node_id,
        node_name: position.node_name || position.node_id,
        status: position.status,
        initials: PresenceBar.initials(label),
        label: label,
        href: day_href(appointment)
      }
    end)
  end

  # The appointment's view is its day: /day?date= lands the calendar on the
  # visit's day (FlightLive's sibling host view), where the read-only detail
  # sheet is one click away.
  defp day_href(%Appointment{scheduled_at: scheduled_at}) do
    "/day?date=" <> Date.to_iso8601(DateTime.to_date(scheduled_at))
  end

  defp day_href(_unresolved), do: "/day"

  # --- the live updates ----------------------------------------------------------

  # The broadcast is a hint, the query is the truth: re-fetch positions and
  # push the fresh markers to the hook, which moves the avatars in place.
  @impl true
  def handle_info(%{"event" => "token_moved"} = _payload, socket) do
    {:noreply, push_markers(socket)}
  end

  def handle_info(:refresh_positions, socket) do
    Process.send_after(self(), :refresh_positions, 5_000)
    {:noreply, push_markers(socket)}
  end

  # Presence broadcasts (the nav's who-else-is-here chip rides this route's
  # topic); anything else is not ours.
  def handle_info(msg, socket) do
    case AshA2ui.Presence.handle_broadcast(msg, ClinicDemoWeb.A2uiPresence, socket) do
      {:noreply, socket} -> {:noreply, socket}
      :ignored -> {:noreply, socket}
    end
  end

  defp push_markers(socket) do
    socket = reload_positions(socket)
    push_event(socket, "flight_positions", %{positions: socket.assigns.markers})
  end
end
