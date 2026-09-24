defmodule ClinicDemoWeb.PageControllerTest do
  use ClinicDemoWeb.ConnCase

  # `/` is the clinic board now; the static landing copy lives at /home.
  test "GET /home", %{conn: conn} do
    conn = get(conn, ~p"/home")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end

  # CLIN-6: the capstone slideshow. The deck is a committed static page
  # (priv/static/deck/); /deck serves its index, Plug.Static the rest.
  test "GET /deck serves the slideshow", %{conn: conn} do
    conn = get(conn, ~p"/deck")
    body = html_response(conn, 200)
    assert conn.status == 200
    assert body =~ "The Vet Clinic Capstone"
    # the navigation bundle is external (the app CSP pins inline scripts)
    assert body =~ ~s(src="/deck/deck.js")
  end

  test "GET /deck/capstone-deck.pptx serves the download", %{conn: conn} do
    conn = get(conn, ~p"/deck/capstone-deck.pptx")
    assert conn.status == 200

    assert get_resp_header(conn, "content-type") |> hd() =~
             "vnd.openxmlformats-officedocument.presentationml.presentation"
  end
end
