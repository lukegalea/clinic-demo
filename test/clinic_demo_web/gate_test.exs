defmodule ClinicDemoWeb.GateTest do
  use ClinicDemoWeb.ConnCase, async: false

  # The gate's config is application env read per request, so tests flip it
  # globally and restore on exit. async: false above keeps neighbours honest.
  # (init_test_session/2 comes from Phoenix.ConnTest, already imported by
  # ConnCase.)

  @session_key "clinic_demo_gate_authenticated"

  setup do
    # Save and restore the real test-env config: on_exit firing a bare
    # delete_env would leave later test files with no :gate key at all —
    # and the plug's default for a missing key is enabled.
    original = Application.get_env(:clinic_demo, :gate)
    Application.put_env(:clinic_demo, :gate, enabled?: true, password: "let-me-in")

    on_exit(fn ->
      if original,
        do: Application.put_env(:clinic_demo, :gate, original),
        else: Application.delete_env(:clinic_demo, :gate)
    end)

    :ok
  end

  describe "the endpoint plug" do
    test "redirects an unauthenticated request to the gate, carrying where it was going", %{
      conn: conn
    } do
      conn =
        conn
        |> init_test_session(%{})
        |> get("/day")

      assert redirected_to(conn) == "/gate?next=%2Fday"
    end

    test "preserves the query string in the redirect target" do
      conn =
        build_conn()
        |> init_test_session(%{})
        |> get("/visits", %{status: "open"})

      assert redirected_to(conn) == "/gate?next=%2Fvisits%3Fstatus%3Dopen"
    end

    test "lets /health and /gate through unauthenticated", %{conn: conn} do
      assert conn |> get("/health") |> text_response(200) =~ "ok"

      assert build_conn() |> init_test_session(%{}) |> get("/gate") |> html_response(200) =~
               "password"
    end

    test "admits a session that has entered", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{@session_key => true})
        |> get("/deck")

      assert html_response(conn, 200)
      refute conn.halted
    end

    test "does nothing when disabled (the test env default)", %{conn: conn} do
      Application.put_env(:clinic_demo, :gate, enabled?: false)

      conn =
        conn
        |> init_test_session(%{})
        |> get("/deck")

      assert html_response(conn, 200)
      refute conn.halted
    end
  end

  describe "the gate page" do
    test "admits on the correct password and lands on `next`", %{conn: conn} do
      csrf = fetch_csrf_from_gate()

      conn =
        conn
        |> init_test_session(%{})
        |> post("/gate", %{"_csrf_token" => csrf, "password" => "let-me-in", "next" => "/day"})

      assert redirected_to(conn) == "/day"
      assert get_session(conn, @session_key) == true
    end

    test "refuses a wrong password with a 401 and no session flag", %{conn: conn} do
      csrf = fetch_csrf_from_gate()

      conn =
        conn
        |> init_test_session(%{})
        |> post("/gate", %{"_csrf_token" => csrf, "password" => "hunter2", "next" => "/day"})

      assert html_response(conn, 401) =~ "not the demo password"
      assert get_session(conn, @session_key) != true
    end
  end

  describe "safe_next?/1" do
    test "accepts same-app relative paths" do
      assert ClinicDemoWeb.Gate.safe_next?("/")
      assert ClinicDemoWeb.Gate.safe_next?("/day?lane=high")
    end

    test "rejects protocol-relative, scheme'd, backslash and newline payloads" do
      refute ClinicDemoWeb.Gate.safe_next?("//evil.com")
      refute ClinicDemoWeb.Gate.safe_next?("https://evil.com")
      refute ClinicDemoWeb.Gate.safe_next?("/\\evil.com")
      refute ClinicDemoWeb.Gate.safe_next?("/day\r\nSet-Cookie: x=y")
      refute ClinicDemoWeb.Gate.safe_next?(String.duplicate("/a", 300))
      refute ClinicDemoWeb.Gate.safe_next?(nil)
    end
  end

  # The gate POST is CSRF-protected like every browser POST: fetch the page
  # first, then lift the token out of the form. (Fetching also seeds this
  # test process's CSRF dictionary, so the token verifies.)
  defp fetch_csrf_from_gate do
    html =
      build_conn()
      |> init_test_session(%{})
      |> get("/gate")
      |> html_response(200)

    case Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, html) do
      [_, token] -> token
      _ -> raise "no csrf token in the gate form"
    end
  end
end
