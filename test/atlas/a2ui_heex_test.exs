defmodule Atlas.A2uiHeexTest do
  @moduledoc "SPIKE: the server-side HEEx renderer over the contract surface's real messages."

  use ClinicDemo.DataCase, async: true

  import Phoenix.LiveViewTest

  require Ash.Query

  setup do
    :ok = ClinicDemo.Clm.Seeds.run()

    contract =
      ClinicDemo.Clm.Contract
      |> Ash.Query.filter(name == "Landscaping & snow removal, North portfolio")
      |> Ash.read_one!()

    ui = ClinicDemoWeb.A2ui.ContractUI
    context_state = AshA2ui.Info.context_state_for(ui, %{"contract" => contract.id}, actor: nil)
    messages = AshA2ui.Info.build_surface(ui, context_state: context_state)

    %{surface: Atlas.A2uiHeex.parse(messages)}
  end

  test "renders the read-only screen from the same JSON the Lit catalog gets", %{surface: surface} do
    html = render_component(&Atlas.A2uiHeex.surface/1, surface: surface)

    # Detail card, List rows (row-relative bindings) and a data grid.
    assert html =~ "Uploaded paper"
    assert html =~ "Commercial general liability"
    assert html =~ "Harbourfront Tower"
    # A date-only value is read as a date: no day lost to a time zone.
    assert html =~ "Dec 31, 2026"
  end

  test "counts what it renders and the interactive parts it skips", %{surface: surface} do
    stats = Atlas.A2uiHeex.stats(surface)

    assert stats.total == stats.rendered + stats.skipped
    assert stats.skipped_types["Button"] > 0
  end
end
