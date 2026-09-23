defmodule ClinicDemoWeb.A2ui.SurfaceChrome do
  @moduledoc """
  Host chrome shared by the a2ui surface LiveViews: the presence bar row
  and the thin wrappers that wire `AshA2ui.Presence` into the
  LiveRenderer's injected mount/handle_info contract.

  Every surface LiveView in `A2uiLive` overrides `mount/3` and
  `handle_info/2` like this:

      @impl true
      def mount(params, session, socket) do
        {:ok, socket} = AshA2ui.LiveRenderer.mount(__ash_a2ui_config__(), params, session, socket)
        {:ok, SurfaceChrome.mount_presence(socket, "clinic_schedule")}
      end

      @impl true
      def handle_info(msg, socket) do
        SurfaceChrome.handle_info(msg, __ash_a2ui_config__(), socket)
      end

  Presence tracks the acting clinician — key: clinician id, label: full
  name, per `AshA2ui.Presence`'s stable-key contract. An anonymous visitor
  is not tracked at all (there is no stable key to offer them) and sees an
  empty bar; the surfaces' "No one is acting." banner already tells them
  why every button refuses.
  """

  alias ClinicDemoWeb.A2uiPresence

  use Phoenix.Component

  attr :presences, :list,
    default: [],
    doc: "rows from `AshA2ui.Presence.mount_surface/4` (%{key, label})"

  @doc """
  The surface header: the avatar stack, right-aligned above the surface
  container. Renders nothing when nobody is tracked — an empty group box
  would just be noise above an empty state.
  """
  def surface_header(assigns) do
    ~H"""
    <div :if={@presences != []} class="flex items-center justify-end">
      <AshA2ui.PresenceBar.bar presences={@presences} max_visible={5} />
    </div>
    """
  end

  @doc """
  Mounts surface presence for the acting clinician on `surface_id`; assigns
  an empty rows list when nobody is acting.
  """
  def mount_presence(socket, surface_id) do
    case socket.assigns[:a2ui_actor] do
      %{id: id, label: label} when is_binary(id) and is_binary(label) ->
        AshA2ui.Presence.mount_surface(A2uiPresence, socket, surface_id, key: id, label: label)

      _ ->
        Phoenix.Component.assign(socket, :a2ui_presences, [])
    end
  end

  @doc """
  The surfaces' `handle_info/2`: presence broadcasts refresh the rows assign,
  everything else falls through to the LiveRenderer's notification handling
  (a no-op on hosts without `:pubsub` configured).
  """
  def handle_info(msg, config, socket) do
    case AshA2ui.Presence.handle_broadcast(msg, A2uiPresence, socket) do
      {:noreply, socket} ->
        {:noreply, socket}

      :ignored ->
        {:noreply, AshA2ui.LiveRenderer.handle_notification(config, msg, socket)}
    end
  end
end
