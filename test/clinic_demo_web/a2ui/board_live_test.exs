defmodule ClinicDemoWeb.A2ui.BoardLiveTest do
  @moduledoc """
  The time-travel control's host-side contract: `?as_of=` puts the board in
  read-only history mode (the "Viewing as of" indicator is the visible half
  of that), its absence is the live board, and an unparseable instant falls
  back to the present — the DayLive `?date=` convention.

  The a2ui surface itself hydrates inside shadow DOM from an async build;
  what these tests assert is the host chrome around it. `async: false`
  because the surface build runs in a task, which needs the shared sandbox
  to read.
  """

  use ClinicDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "without ?as_of= the board is live: control present, indicator absent", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "View the board as of"
    assert html =~ "time-travel-form"
    refute html =~ "Viewing as of"
  end

  test "an ?as_of= deep link shows the viewing indicator", %{conn: conn} do
    as_of = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    {:ok, _view, html} = live(conn, ~p"/?as_of=#{DateTime.to_iso8601(as_of)}")

    assert html =~ "Viewing as of"
    assert html =~ Calendar.strftime(as_of, "%Y-%m-%d %H:%M UTC")
    assert html =~ "read-only"
  end

  test "an unparseable ?as_of= falls back to the present", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/?as_of=not-an-instant")

    assert html =~ "View the board as of"
    refute html =~ "Viewing as of"
  end

  test "the picker patches the instant: the payload a browser posts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # form/3 only accepts keys that exist as named inputs in the DOM, so a
    # nameless picker fails here instead of crashing the LiveView in use.
    view
    |> form("#time-travel-form", %{"time_travel" => %{"as_of" => "2026-10-15T08:00"}})
    |> render_change()

    assert_patch(view, "/?as_of=2026-10-15T08%3A00%3A00Z")
    assert render(view) =~ "Viewing as of"
  end

  test "a patched instant rebuilds the surface: delete first, then create", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_async(view)

    as_of = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    render_patch(view, ~p"/?as_of=#{DateTime.to_iso8601(as_of)}")
    render_async(view)

    # The client already holds clinic_board; a bare createSurface for it is
    # rejected and the old cards stay on screen.
    assert_push_event(view, "a2ui:messages", %{
      messages: [
        %{"deleteSurface" => %{"surfaceId" => "clinic_board"}},
        %{"createSurface" => %{"surfaceId" => "clinic_board"}} | _rest
      ]
    })
  end
end
