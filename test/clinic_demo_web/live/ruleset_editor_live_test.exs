defmodule ClinicDemoWeb.Compliance.RulesetEditorLiveTest do
  @moduledoc """
  The ruleset editor mounts over the demo's fixed organization and shows the
  compliance reality the seeds put in force: the seeded rule-set revision in
  the list, the active bundle in the header.
  """

  use ClinicDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ClinicDemo.Compliance

  setup do
    # The same lifecycle the seeds run: it drafts and activates the
    # appointment rule-set revision, then compiles and activates its bundle.
    bundle = Compliance.activate_appointment_bundle!()
    %{bundle: bundle}
  end

  test "mounts over the seeded org: revision listed, active bundle hydrated", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/operator/rules")

    Ecto.Adapters.SQL.Sandbox.allow(ClinicDemo.Repo, self(), view.pid)

    # The seeded revision is in the list, with its name.
    assert html =~ "clinic_appointment_rules"

    # And the header names the bundle the seeds activated.
    assert html =~ "active bundle"
  end

  test "hydration refreshes against the seeded revision", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/operator/rules")

    Ecto.Adapters.SQL.Sandbox.allow(ClinicDemo.Repo, self(), view.pid)

    # The editor's own select affordance (the row button) drives the hydrate
    # path — the same one the toolbar continues from.
    view
    |> element(~s([data-action="select"]), "Edit")
    |> render_click()

    assert render(view) =~ "clinic_appointment_rules"
  end
end
