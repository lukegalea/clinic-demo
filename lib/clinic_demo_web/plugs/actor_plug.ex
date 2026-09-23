defmodule ClinicDemoWeb.ActorPlug do
  @moduledoc """
  The host-side wrapper around `AshA2ui.ActorPlug`, mounted at the
  **endpoint** — the switch path is not a route, so a pipeline plug would
  never see it (pipelines run only after a route matches).

  Three jobs the framework plug leaves to the host:

    * **Graceful stale roster.** The framework plug answers a pick of a
      clinician who has since been retired with a raw `422 "unknown actor"`
      plain-text page — the audit hit it by clicking a roster link rendered
      before a mid-session retirement. Here the unknown id instead puts an
      error flash on `/acting-as`, where the picker is, and redirects there.
      (The framework's own picker view renders no flash, so the root layout
      carries the host flash area that displays it.)

    * **The acting-as pill.** The nav pill never said WHO was acting because
      root layouts render from conn assigns, and the actor only existed in
      LiveView socket assigns. This plug resolves the session's actor id to
      its label once per request and puts it on the conn for the root layout.

    * **The nav's current path.** `assigns[:current_path]` feeds
      `AshA2ui.PresenceBar.nav_current_attrs/2` in the root layout.

  A valid pick keeps the framework contract verbatim: id validated through
  `AshA2ui.Actor.load/1`, stored under `AshA2ui.Actor.session_key/0`, 302
  back to the referer. Runs after `Plug.Session`, so the session is already
  fetched; the stale path fetches query params and flash itself because the
  endpoint pipeline has not run them yet.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> assign_current_path()
    |> assign_actor_label()
    |> maybe_switch_actor()
  end

  # The nav's aria-current contract keys on the path; the root layout reads
  # this assign. Accurate on every document load — live navigation within
  # live_session :a2ui keeps the document, same as the rest of the chrome.
  defp assign_current_path(conn) do
    assign(conn, :current_path, conn.request_path)
  end

  # One primary-key read per request with a session id — the same read the
  # Actor on_mount already performs on every LiveView mount. Skipped on the
  # switch path itself, where the session is about to be rewritten. The
  # session fetch is idempotent and needed here because this plug runs at
  # the endpoint, before any pipeline's fetch_session.
  defp assign_actor_label(%{path_info: ["a2ui", "actor"]} = conn), do: conn

  defp assign_actor_label(conn) do
    conn = fetch_session(conn)

    case get_session(conn, AshA2ui.Actor.session_key()) do
      nil ->
        conn

      id ->
        case AshA2ui.Actor.load(id) do
          %AshA2ui.Actor{label: label} when is_binary(label) and label != "" ->
            assign(conn, :a2ui_actor_label, label)

          _ ->
            conn
        end
    end
  end

  defp maybe_switch_actor(%{path_info: ["a2ui", "actor"], method: "GET"} = conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case AshA2ui.Actor.load(conn.query_params["id"] || "") do
      %AshA2ui.Actor{} = actor ->
        conn
        |> put_session(AshA2ui.Actor.session_key(), actor.id)
        |> put_resp_header("location", back(conn))
        |> send_resp(302, "")
        |> halt()

      nil ->
        conn
        # fetch_flash registers the before_send that persists the flash
        # through the redirect (session "phoenix_flash"); the next request's
        # fetch_live_flash picks it up and the root layout renders it.
        |> Phoenix.Controller.fetch_flash([])
        |> Phoenix.Controller.put_flash(
          :error,
          "That clinician is no longer on the active roster — pick someone current."
        )
        |> Phoenix.Controller.redirect(to: "/acting-as")
        |> halt()
    end
  end

  defp maybe_switch_actor(%{path_info: ["a2ui", "actor"]} = conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(405, "GET only\n")
    |> halt()
  end

  defp maybe_switch_actor(conn), do: conn

  # Same back-to-referer contract as the framework plug: sessions are written
  # over HTTP, so land the user where they clicked from. A referer-less
  # request (curl, a fresh tab) lands on the app root.
  defp back(conn) do
    case get_req_header(conn, "referer") do
      [referer | _] -> URI.parse(referer).path || "/"
      [] -> "/"
    end
  end
end
