defmodule ClinicDemoWeb.HealthController do
  @moduledoc """
  `GET /health` → `200 "ok"` — the Fly load balancer's health-check target.

  Deliberately outside the `:browser` pipeline: a health probe carries no
  session, no CSRF token and no browser, and must answer before any of
  that machinery runs. The endpoint-level gate exempts the path, and
  `force_ssl` in config/prod.exs excludes it, so the check cannot be
  bounced by either an auth redirect or an http→https rewrite.
  """

  use ClinicDemoWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok\n")
  end
end
