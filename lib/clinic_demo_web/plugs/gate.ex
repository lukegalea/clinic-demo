defmodule ClinicDemoWeb.Gate do
  @moduledoc """
  The demo gate: one shared password in front of the whole clinic.

  The app ships with zero authentication — every surface is the public
  internet the moment it is deployed. This plug puts a single shared
  secret (the `DEMO_GATE_PASSWORD` env var in production) in front of
  everything, which is the right shape for a demo: no accounts, no
  registration, one password Luke hands out with the URL.

  Mounted at the **endpoint**, after `Plug.Session` and before the router
  — the same position `ActorPlug` holds one plug later. Any path it does
  not exempt gets a 302 to `/gate?next=<where-you-were-going>`; the gate
  page's POST compares the password with `Plug.Crypto.secure_compare` and
  writes a session flag, which this plug checks on every later request.

  LiveView traffic gets the same treatment one layer up: `GateOnMount`
  runs in the router's `live_session`s and redirects unauthenticated
  mounts. (The `/live` socket itself connects *before* this plug can run —
  socket handshakes are upgraded at the endpoint top — but a websocket
  without a mounted document is dead weight, and the document only renders
  for an authenticated session.)

  Exempt: `/health` (the Fly load balancer's check target — it must answer
  with no session and no human) and `/gate` itself. Static assets need no
  exemption: `Plug.Static` runs upstream of this plug and serves them
  before the router is ever reached.

  Configuration lives under `config :clinic_demo, :gate`:

    * `enabled?` — `true` by default; `false` in the test env, so the
      suite exercises routes, not the gate (the gate's own behaviour is
      covered in `ClinicDemoWeb.GateTest`, which flips the flag per test).
    * `password` — required in prod (runtime.exs raises without
      `DEMO_GATE_PASSWORD`); dev falls back to a known value so
      `mix phx.server` stays a one-liner.
  """

  @behaviour Plug

  import Plug.Conn

  # The session flag written on a correct password. Lives in the same signed
  # cookie session the a2ui actor switcher already uses.
  @session_key "clinic_demo_gate_authenticated"

  # Paths reachable without the password. `path_info` shapes, so `/health`
  # exactly — not `/healthz`, not `/health/anything`.
  @exempt_paths MapSet.new([["health"], ["gate"]])

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      not enabled?() ->
        conn

      open?(conn) ->
        conn

      true ->
        conn = fetch_session(conn)

        if get_session(conn, @session_key) == true do
          conn
        else
          conn |> redirect_to_gate() |> halt()
        end
    end
  end

  # Marks the session as through-the-gate. Called by GateController after a
  # `secure_compare` hit.
  def enter(conn), do: conn |> fetch_session() |> put_session(@session_key, true)

  def enabled?, do: Keyword.get(gate_config(), :enabled?, true)

  def password, do: Keyword.get(gate_config(), :password)

  # A redirect target is only ever a same-app relative path: one leading
  # slash (protocol-relative `//evil.com` out), no backslashes (browsers
  # fold `\` into `/`), no CR/LF (header injection out), bounded size.
  # Everything else falls back to "/".
  def safe_next?(next) when is_binary(next) and byte_size(next) <= 512 do
    String.starts_with?(next, "/") and not String.contains?(next, ["\\", "\r", "\n"]) and
      not String.starts_with?(next, "//")
  end

  def safe_next?(_), do: false

  defp open?(conn), do: MapSet.member?(@exempt_paths, conn.path_info)

  defp redirect_to_gate(conn) do
    target = full_path(conn)
    Phoenix.Controller.redirect(conn, to: "/gate?next=" <> URI.encode_www_form(target))
  end

  defp full_path(%{query_string: ""} = conn), do: conn.request_path
  defp full_path(conn), do: conn.request_path <> "?" <> conn.query_string

  defp gate_config, do: Application.get_env(:clinic_demo, :gate, [])
end
