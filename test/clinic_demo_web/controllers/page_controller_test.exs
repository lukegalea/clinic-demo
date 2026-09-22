defmodule ClinicDemoWeb.PageControllerTest do
  use ClinicDemoWeb.ConnCase

  # `/` is the clinic board now; the static landing copy lives at /home.
  test "GET /home", %{conn: conn} do
    conn = get(conn, ~p"/home")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end
end
