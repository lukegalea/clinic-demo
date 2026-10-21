defmodule ClinicDemoWeb.Clm.ContractsHubLiveTest do
  @moduledoc """
  The hub's HEEx shell: workspace bar, stat cards, and cards that are links
  setting the declared table's filter through the URL. `async: false` because
  the surface builds in a task that reads the shared sandbox.
  """

  use ClinicDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    :ok = ClinicDemo.Clm.Seeds.run()
  end

  test "the hub shows the workspace bar and counts contracts by status", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/contracts")

    assert has_element?(view, "#clm-workspace-bar a[aria-current=page]", "All contracts")

    counts =
      ClinicDemo.Clm.list_contracts!(load: [:status, :verified?])
      |> Enum.frequencies_by(& &1.status)

    assert has_element?(view, "#clm-stat-expiring", "#{Map.get(counts, :expiring_soon, 0)}")
    assert has_element?(view, "#clm-stat-active", "#{Map.get(counts, :active, 0)}")
    assert has_element?(view, "#clm-stat-expired", "#{Map.get(counts, :expired, 0)}")
  end

  test "a card links to the hub with the declared filter set", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/contracts")

    assert has_element?(
             view,
             ~s(#clm-stat-expiring[href="/contracts?q[filters][status]=expiring_soon"])
           )
  end

  test "the first paint already shows the surface placeholder", %{conn: conn} do
    # The dead render: what the browser paints before any JS has run.
    html = conn |> get(~p"/contracts") |> html_response(200)
    document = LazyHTML.from_document(html)

    assert LazyHTML.query(document, "#ash-a2ui-surface [data-atlas-placeholder][aria-busy=true]")
           |> Enum.count() == 1
  end

  test "a contract link opens its page", %{conn: _conn} do
    [contract | _] = ClinicDemo.Clm.list_contracts!()

    assert ClinicDemoWeb.A2ui.Links.target_path("contract", contract.id) ==
             "/contracts/#{contract.id}"

    assert ClinicDemoWeb.A2ui.Links.surface_for({:surface, "contract"}, %{}) == "contract"
  end
end
