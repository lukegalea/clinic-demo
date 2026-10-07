defmodule ClinicDemoWeb.GateOnMount do
  @moduledoc """
  The gate's LiveView half: an `on_mount` hook listed in the router's
  `live_session`s, redirecting any mount whose session has not passed the
  gate.

  It exists because the socket handshake (the `/live` connect at the top of
  the endpoint) happens *before* `ClinicDemoWeb.Gate` runs — a websocket
  cannot be redirected at the plug layer. What the plug cannot stop, this
  hook does: an unauthenticated mount is halted with a redirect to
  `/gate?next=<the-mount-path>`, exactly what the plug would have served.
  Authenticated mounts pass through untouched, as does every mount when
  the gate is disabled (test env).

  Appended after `AshA2ui.Actor` in `live_session :a2ui` — actor resolution
  first, then the gate; both must pass before any surface renders. Any
  future `live_session` (or an ash_authentication-style one) lists this
  module too, so the gate rides along wherever LiveViews mount.
  """

  import Phoenix.LiveView

  def on_mount(_arg, _params, session, socket) do
    if ClinicDemoWeb.Gate.enabled?() and locked?(session) do
      {:halt, redirect(socket, to: gate_url(socket))}
    else
      {:cont, socket}
    end
  end

  # The session reaches on_mount as a string-keyed map (it is the Plug
  # session snapshot taken at socket connect). "Locked" = no gate flag in
  # the session.
  defp locked?(session),
    do: Map.get(session, "clinic_demo_gate_authenticated") != true

  # Send people back to the page they asked for. The mount path comes off
  # the connect info's request URI; anything the plug's own validator would
  # refuse falls back to the root, and the whole thing is query-encoded
  # before it rides in /gate's `next` param.
  defp gate_url(socket) do
    next =
      case get_connect_info(socket, :uri) do
        %URI{path: path, query: nil} when is_binary(path) -> path
        %URI{path: path, query: query} when is_binary(path) -> path <> "?" <> query
        _ -> "/"
      end

    next = if ClinicDemoWeb.Gate.safe_next?(next), do: next, else: "/"
    "/gate?next=" <> URI.encode_www_form(next)
  end
end
