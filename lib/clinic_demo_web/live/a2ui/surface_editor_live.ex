defmodule ClinicDemoWeb.A2ui.SurfaceEditorLive do
  @moduledoc """
  The operator's surface editor: ash_a2ui's self-hosted composer
  (`AshA2ui.Web.ComposerLive`) over the demo's declared surfaces.

  The composer is the human counterpart to the agent-composed surfaces lane:
  browse every surface in `ClinicDemoWeb.A2ui.Surfaces`, import it into the
  dynamic spec vocabulary (with the Importer's rejections shown honestly),
  edit the spec as structured rows with live validation, preview the resolve,
  and export the equivalent standalone module source. Like
  `ClinicDemoWeb.AgentLive`'s composing, nothing here writes back — export is
  a paste-ready source, so promoting a surface stays a checked-in act.

  Host wiring, per the `SurfaceChrome` pattern the surfaces share:

    * the allowlist/`surfaces` config comes from the catalogue, so a surface
      added there becomes importable here without another edit;
    * presence tracks the acting clinician on this page's own topic
      (`clinic_surface_editor`) — this LiveView is a tracker like every other
      surface, even though the nav row does not list it.

  The page itself is inside `live_session :a2ui`, so `on_mount AshA2ui.Actor`
  has already resolved the acting clinician by the time mount runs.
  """

  alias AshA2ui.Web.ComposerLive
  alias ClinicDemoWeb.A2ui.SurfaceChrome
  alias ClinicDemoWeb.A2ui.Surfaces
  alias ClinicDemoWeb.A2uiPresence

  use AshA2ui.Web.ComposerLive,
    surfaces: Enum.map(Surfaces.all(), & &1.ui),
    allowlist: Surfaces.composer_allowlist(),
    export_module: "ClinicDemoWeb.A2ui.ComposedSurface"

  @surface_id "clinic_surface_editor"

  @impl true
  def mount(params, session, socket) do
    {:ok, socket} = ComposerLive.mount(__composer_config__(), params, session, socket)

    {:ok, SurfaceChrome.mount_presence(socket, @surface_id)}
  end

  @impl true
  def handle_info(msg, socket) do
    case AshA2ui.Presence.handle_broadcast(msg, A2uiPresence, socket) do
      {:noreply, socket} ->
        {:noreply, socket}

      :ignored ->
        ComposerLive.handle_info(msg, socket)
    end
  end
end
