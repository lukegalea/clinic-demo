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

    html = render_click(view, "import", %{"module" => "ClinicDemoWeb.A2ui.PatientUI"})

    # The editor over the imported spec — resource, honest rejections (if the
    # declared surface has any), and the resolved preview.
    assert html =~ "imported from ClinicDemoWeb.A2ui.PatientUI"
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
