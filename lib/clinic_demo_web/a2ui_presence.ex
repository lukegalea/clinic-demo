defmodule ClinicDemoWeb.A2uiPresence do
  @moduledoc """
  The host-owned `Phoenix.Presence` replica for the a2ui surfaces —
  `AshA2ui.Presence` is *used*, not started, so each host supervises one
  module per PubSub (see its moduledoc's host wiring section). Surfaced by
  `ClinicDemoWeb.A2ui.SurfaceChrome` on the surfaces in `A2uiLive`.
  """

  use AshA2ui.Presence, pubsub_server: ClinicDemo.PubSub
end
