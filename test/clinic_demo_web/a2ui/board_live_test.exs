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
end
