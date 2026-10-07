defmodule ClinicDemoWeb.GateController do
  use ClinicDemoWeb, :controller

  @moduledoc """
  The gate page itself: `GET /gate` renders the password form, `POST /gate`
  checks it. Reachable without the session flag — it is how a session gets
  one — and exempt from `ClinicDemoWeb.Gate` for exactly that reason.

  The POST compares against the configured password with
  `Plug.Crypto.secure_compare` (constant-time, length-neutral) and writes
  the session flag via `ClinicDemoWeb.Gate.enter/1`, then redirects to the
  `next` param — validated through `Gate.safe_next?/1`, so only same-app
  relative paths survive. A wrong password re-renders the form with a 401
  and no session change. The form rides the `:browser` pipeline like every
  other route, so the POST is CSRF-protected like every other POST.
  """

  def show(conn, params) do
    conn
    # The gate is a standalone page — it must render (and keep rendering
    # after a failed attempt) without any of the chrome assigns the root
    # layout expects from app surfaces.
    |> put_root_layout(false)
    |> put_layout(false)
    |> render(:show, next: next_from(params), error: nil)
  end

  def create(conn, %{"password" => password} = params)
      when is_binary(password) and password != "" do
    expected = ClinicDemoWeb.Gate.password()

    if is_binary(expected) and expected != "" and Plug.Crypto.secure_compare(password, expected) do
      conn
      |> ClinicDemoWeb.Gate.enter()
      |> redirect(to: next_from(params))
    else
      conn
      |> put_status(401)
      |> put_root_layout(false)
      |> put_layout(false)
      |> render(:show, next: next_from(params), error: "That is not the demo password.")
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(401)
    |> put_root_layout(false)
    |> put_layout(false)
    |> render(:show, next: "/", error: "That is not the demo password.")
  end

  defp next_from(params) do
    case ClinicDemoWeb.Gate.safe_next?(params["next"]) do
      true -> params["next"]
      false -> "/"
    end
  end
end
