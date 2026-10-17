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

  test "a card's button reaches the renderer: Check in checks the visit in", %{conn: conn} do
    staff = %{id: "00000000-0000-0000-0000-0000000000b1", role: :veterinarian}

    {:ok, vet} =
      ClinicDemo.Scheduling.hire_clinician(
        %{
          full_name: "Dr. Button Test",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: staff
      )

    # CheckIn's candidates are the active nurses, written when the visit is
    # booked; the engine refuses a check-in by anyone else.
    {:ok, nurse} =
      ClinicDemo.Scheduling.hire_clinician(%{full_name: "Button Nurse", role: :nurse},
        actor: staff
      )

    {:ok, patient} =
      ClinicDemo.Scheduling.register_patient(
        %{
          name: "Button Test Animal",
          species: :dog,
          owner_email: "button-#{System.unique_integer([:positive])}@example.com"
        },
        actor: staff
      )

    # Severity 1 on an adult dog triages routine: the card sits in the
    # Booked stage's routine row, board_booked__routine.
    appointment =
      ClinicDemo.Scheduling.book_appointment!(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 2, :hour),
          reason: "Button test",
          severity: 1
        },
        actor: staff
      )

    {:ok, view, _html} =
      conn
      |> init_test_session(%{AshA2ui.Actor.session_key() => nurse.id})
      |> live(~p"/")

    render_async(view)

    # Drop what the connected mount pushed, so what is left after the click
    # is what the action pushed.
    _initial = drain_pushed_messages(view)

    # The envelope the browser sends for the card's Check in button.
    render_hook(view, "a2ui:action", %{
      "version" => "v0.9.1",
      "action" => %{
        "name" => "invoke",
        "surfaceId" => "clinic_board",
        "sourceComponentId" => "row_action_board_booked__routine_check_in_button",
        "context" => %{
          "action" => "check_in",
          "component" => "board_booked__routine",
          "recordId" => appointment.id
        }
      }
    })

    assert ClinicDemo.Scheduling.get_appointment!(appointment.id).status == :checked_in

    # The card moved one stage along its own row: from Booked to In visit,
    # still routine.
    assert cells_holding(appointment.id) == ["board_in_visit__routine"]

    # And the open board was told so: the action's refresh rewrote every
    # cell, with the card under its new cell and gone from its old one.
    pushed = view |> drain_pushed_messages() |> records_updates()

    assert pushed |> Map.keys() |> Enum.sort() == Enum.sort(board_cells())
    assert holds?(pushed["board_in_visit__routine"], appointment.id)
    refute holds?(pushed["board_booked__routine"], appointment.id)
  end

  test "the board is stages by triage rows, each row in its tone" do
    model = board_model()

    assert model["records"] |> Map.keys() |> Enum.sort() == Enum.sort(board_cells())

    assert Map.take(model, Enum.map(~w(emergency urgent soon routine untriaged), &tone_key/1)) ==
             %{
               tone_key("emergency") => "danger",
               tone_key("urgent") => "warning",
               tone_key("soon") => "info",
               tone_key("routine") => "success",
               tone_key("untriaged") => "neutral"
             }
  end

  defp tone_key(row), do: "_swimlane_tone_board__#{row}"

  defp board_cells do
    for row <- ~w(emergency urgent soon routine untriaged),
        stage <- ~w(booked in_visit discharged closed),
        do: "board_#{stage}__#{row}"
  end

  # Every "a2ui:messages" push already in the test's mailbox, in order. The
  # LiveView process sends them before it replies, so after a render_* call
  # they have all arrived.
  defp drain_pushed_messages(%{proxy: {ref, _topic, _pid}} = view) do
    receive do
      {^ref, {:push_event, "a2ui:messages", %{messages: messages}}} ->
        messages ++ drain_pushed_messages(view)
    after
      0 -> []
    end
  end

  # The last records rewrite pushed for each cell, by cell name.
  defp records_updates(messages) do
    for %{"updateDataModel" => %{"path" => "/records/" <> cell, "value" => rows}} <- messages,
        into: %{},
        do: {cell, rows}
  end

  defp holds?(rows, id) when is_list(rows), do: Enum.any?(rows, &match?(%{"id" => ^id}, &1))

  defp board_model do
    ClinicDemoWeb.A2ui.BoardUI
    |> AshA2ui.Info.build_surface(actor: nil)
    |> Enum.find_value(fn
      %{"updateDataModel" => %{"path" => "/", "value" => value}} -> value
      _other -> nil
    end)
  end

  defp cells_holding(appointment_id) do
    for {cell, records} <- board_model()["records"],
        Enum.any?(records, &match?(%{"id" => ^appointment_id}, &1)),
        do: cell
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
