defmodule ClinicDemoWeb.A2ui.SurfaceEditorLiveTest do
  @moduledoc """
  The surface editor mounts over the demo's declared-surface catalogue: the
  browse page lists one card per surface in `ClinicDemoWeb.A2ui.Surfaces`,
  importing one lands in the editor with the imported spec resolving, and the
  operator hub's Operations index links here.
  """

  use ClinicDemoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClinicDemoWeb.A2ui.Surfaces

  test "browse lists every declared surface from the catalogue", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/operator/surfaces")

    assert html =~ "Surface editor"

    # One card per catalogue surface, by module short name.
    for surface <- Surfaces.all() do
      assert html =~ surface.ui |> Module.split() |> List.last()
    end
  end

  test "importing a surface lands in the editor with the spec resolved", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/operator/surfaces")

    # ProcessUI, not PatientUI: the dynamic spec vocabulary has no `context`
    # entity and no per-table `resource`, so a master/detail surface (Patients,
    # Clinicians) imports without its related table's resource and does not
    # resolve. That is an ash_a2ui Dynamic gap, not this editor's.
    html = render_click(view, "import", %{"module" => "ClinicDemoWeb.A2ui.ProcessUI"})

    # The editor over the imported spec — resource, honest rejections (if the
    # declared surface has any), and the resolved preview.
    assert html =~ "imported from ClinicDemoWeb.A2ui.ProcessUI"
    assert html =~ "Spec"
    assert html =~ "Preview — resolves"
  end

  test "the operator hub links the editor from the Operations index", %{conn: conn} do
    conn = get(conn, ~p"/operator")
    html = html_response(conn, 200)

    assert html =~ ~s(href="/operator/surfaces")
    assert html =~ "Surface editor"
  end
end
