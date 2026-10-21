defmodule ClinicDemoWeb.Clm.ContractLiveTest do
  @moduledoc """
  The HEEx shell around the declared contract surface: header, lifecycle and
  the footer's count, which must follow a check made inside the surface.
  `async: false` because the surface builds in a task that reads the shared
  sandbox.
  """

  use ClinicDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  require Ash.Query

  setup do
    :ok = ClinicDemo.Clm.Seeds.run()

    contract =
      ClinicDemo.Clm.Contract
      |> Ash.Query.filter(name == "Landscaping & snow removal, North portfolio")
      |> Ash.read_one!()

    %{contract: contract}
  end

  test "a deep link shows the contract's header, lifecycle and what is left to check",
       %{conn: conn, contract: contract} do
    {:ok, view, _html} = live(conn, ~p"/contracts/#{contract.id}")

    assert has_element?(view, "h1", contract.name)
    assert has_element?(view, "#clm-ai-notice")
    assert has_element?(view, "#clm-lifecycle", "Nov 1, 2026")
    assert has_element?(view, "#clm-lifecycle", "$86,400")
    assert has_element?(view, "#clm-to-check-count", "8 to check")
  end

  test "an id that does not exist shows no contract", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/contracts/#{Ash.UUID.generate()}")

    refute has_element?(view, "#clm-lifecycle")
    assert has_element?(view, "#clm-contract-missing")
  end

  test "confirming a value in the surface updates the footer", %{conn: conn, contract: contract} do
    staff = %{id: "00000000-0000-0000-0000-0000000000c2", role: :veterinarian}

    {:ok, nurse} =
      ClinicDemo.Scheduling.hire_clinician(%{full_name: "Contract Checker", role: :nurse},
        actor: staff
      )

    [value | _] =
      ClinicDemo.Clm.ExtractedValue
      |> Ash.Query.filter(contract_id == ^contract.id and is_nil(confirmed_at))
      |> Ash.Query.sort(position: :asc)
      |> Ash.read!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{AshA2ui.Actor.session_key() => nurse.id})
      |> live(~p"/contracts/#{contract.id}")

    render_async(view)

    # The envelope the browser sends for the row's Confirm button.
    render_hook(view, "a2ui:action", %{
      "version" => "v0.9.1",
      "action" => %{
        "name" => "invoke",
        "surfaceId" => "clm_contract",
        "sourceComponentId" => "row_action_to_check_renewal_terms_confirm_button",
        "context" => %{
          "action" => "confirm",
          "component" => "to_check_renewal_terms",
          "recordId" => value.id,
          "contexts" => %{"contract" => %{"value" => contract.id}}
        }
      }
    })

    assert has_element?(view, "#clm-to-check-count", "7 to check")
  end
end
