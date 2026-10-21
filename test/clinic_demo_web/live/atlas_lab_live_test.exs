defmodule ClinicDemoWeb.AtlasLabLiveTest do
  use ClinicDemoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the HEEx field shows its error only once used, linked by aria-describedby", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/atlas-lab")
    refute html =~ "must be at least 3 characters"

    # LiveViewTest's form/3 only drives native inputs it finds in the server
    # HTML; the form-associated <atlas-text-field> is not one, so these tests
    # send the events the browser would send.
    html =
      render_change(view, "validate", %{
        "_target" => ["lab", "heex"],
        "lab" => %{"heex" => "ab", "lit" => "", "_unused_lit" => ""}
      })

    assert has_element?(
             view,
             ~s(#lab_heex[aria-invalid="true"][aria-describedby="lab_heex-caption lab_heex-error"])
           )

    assert has_element?(view, "#lab_heex-error", "must be at least 3 characters")
    # The untouched Lit field is held to the same rule: no error yet.
    refute html =~ ~s(data-error=)
  end

  test "the Lit field receives its error through data-error once used", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/atlas-lab")

    render_change(view, "validate", %{
      "_target" => ["lab", "lit"],
      "lab" => %{"heex" => "", "lit" => "ab", "_unused_heex" => ""}
    })

    assert has_element?(view, ~s(#lab-lit[data-error="must be at least 3 characters"]))
  end

  test "French labels come from the Bilingual page's real pairs, and lang follows", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/atlas-lab?lang=fr")

    assert has_element?(view, ~s(main[lang="fr"]))

    assert has_element?(
             view,
             "label[for=lab_heex]",
             "Numéro(s) d’identification du Gestionnaire immobilier"
           )

    assert has_element?(
             view,
             ~s|#lab-lit[data-label="Numéro(s) d’identification du Gestionnaire immobilier"]|
           )

    assert has_element?(view, "#atlas-lab-submit", "Ajouter un Gestionnaire immobilier")
  end

  test "a valid form submits every field", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/atlas-lab")

    render_submit(view, "save", %{
      "lab" => %{
        "heex" => "PM-1042",
        "lit" => "PM-2042",
        # What <atlas-multi-select> submits: one entry per choice.
        "properties" => ["Maple Court", "King West Lofts"]
      }
    })

    assert has_element?(view, "#atlas-lab-submitted", ~s(heex="PM-1042"))
    assert has_element?(view, "#atlas-lab-submitted", ~s(lit="PM-2042"))
    assert has_element?(view, "#atlas-lab-submitted", ~s(["Maple Court", "King West Lofts"]))
  end

  test "the multi-select gets its options, its value and its error as data-* attributes",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/atlas-lab")

    assert has_element?(view, ~s(atlas-multi-select#lab-properties[name="lab[properties][]"]))
    assert has_element?(view, ~s|#lab-properties[data-options*="Harbourfront Tower"]|)

    # Nothing chosen: the element still submits one empty entry, so the field
    # counts as used and the server's error comes back.
    render_change(view, "validate", %{
      "_target" => ["lab", "properties"],
      "lab" => %{"heex" => "", "lit" => "", "properties" => [""]}
    })

    assert has_element?(view, ~s(#lab-properties[data-error="choose at least one property"]))

    render_change(view, "validate", %{
      "_target" => ["lab", "properties"],
      "lab" => %{"heex" => "", "lit" => "", "properties" => ["", "Maple Court"]}
    })

    refute has_element?(view, "#lab-properties[data-error]")
    assert has_element?(view, ~s|#lab-properties[data-value='["Maple Court"]']|)
  end

  test "the page carries the hello-badge Lit demo as a plain tag", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/atlas-lab")

    # The server sends only the tag and its attribute; the browser runs the rest.
    assert has_element?(view, ~s(#hello-badge-demo hello-badge[name="Leandro"]))
  end

  test "the modal's primary button tells the server", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/atlas-lab")

    assert has_element?(view, ~s(atlas-modal#award-modal[data-title="Award this project"]))
    view |> element("#award-confirm") |> render_click()

    assert has_element?(view, "#awarded-note")
  end

  test "the server opens the drawer, validates its Lit fields and closes it on save",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/atlas-lab")

    view |> element("#open-vendor-drawer") |> render_click()
    assert_push_event(view, "atlas:open", %{id: "vendor-drawer"})

    # The drawer's fields are Lit (<atlas-text-field>, <atlas-multi-select>),
    # which form/3 cannot see: send what the browser sends.
    render_change(view, "vendor_validate", %{
      "_target" => ["vendor", "name"],
      "vendor" => %{"name" => "ab", "properties" => [""], "_unused_properties" => [""]}
    })

    assert has_element?(view, ~s(#vendor-name[data-error="must be at least 3 characters"]))
    refute has_element?(view, "#vendor-properties[data-error]")

    render_submit(view, "vendor_save", %{
      "vendor" => %{"name" => "GreenScape Landscaping", "properties" => ["Maple Court"]}
    })

    assert_push_event(view, "atlas:close", %{id: "vendor-drawer"})
    assert has_element?(view, "#vendor-saved-note", "GreenScape Landscaping")
    assert has_element?(view, "#vendor-saved-note", "Maple Court")
  end

  test "form recovery without the form's key doesn't crash the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/atlas-lab")

    render_change(view, "vendor_validate", %{"_target" => ["vendor", "name"]})
    assert has_element?(view, "#vendor-drawer")
  end
end
