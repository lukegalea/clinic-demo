defmodule ClinicDemoWeb.FlightLiveTest do
  @moduledoc """
  The flight view's live contract: the published process renders as mermaid
  (server-side source, client-side draw), every live token renders as a
  patient avatar with a deep-link to its day, and a token broadcast — the
  engine's own, on a check-in — moves the marker without a page reload.
  """

  use ClinicDemoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClinicDemo.Rules
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Visits
  alias ClinicDemo.Visits.Instance

  require Ash.Query

  # A UUID, because booking starts a visit process and the instance records
  # who started it in a uuid column.
  @staff %{id: "00000000-0000-0000-0000-0000000000cc", role: :veterinarian}

  setup do
    definition = Visits.latest_published_process!(Rules.process_key()) |> hd()

    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Flight Test",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "Flight Animal",
          species: :dog,
          owner_email: "flight-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    %{definition: definition, vet: vet, patient: patient}
  end

  test "renders the published definition's mermaid source for the client to draw", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, "/flight")

    assert html =~ "flowchart"
    assert html =~ ~s(data-mermaid=)
    # The definition's own element ids round-trip into the source, so the
    # client can position markers by node id.
    assert html =~ "CheckIn"
  end

  test "a live visit renders as a patient marker with a day deep-link", %{
    conn: conn,
    vet: vet,
    patient: patient
  } do
    appointment = book(patient, vet)

    {:ok, _view, html} = live(conn, "/flight")

    # The no-JS fallback carries the same markers the diagram overlays draw:
    # the patient's label, the step the token stands on, and the deep-link.
    assert html =~ "Flight Animal"
    assert html =~ "/day?date="
    assert html =~ "Start_booked"
  end

  test "a token broadcast re-fetches positions and pushes fresh markers", %{
    conn: conn,
    definition: definition,
    vet: vet,
    patient: patient
  } do
    appointment = book(patient, vet)
    instance = instance_for(appointment)
    token = live_token(instance)

    {:ok, view, _html} = live(conn, "/flight")

    payload = AshBpmn.FlightView.token_payload(instance, token)

    Phoenix.PubSub.broadcast(
      ClinicDemo.PubSub,
      AshBpmn.FlightView.definition_topic(definition.id),
      payload
    )

    assert_push_event(view, "flight_positions", %{positions: positions})
    assert marker = Enum.find(positions, &(&1.token_id == token.id))
    # Wherever the engine has the token by now (the inline advance worker
    # may already have walked it past the start event), the pushed marker
    # reports that node.
    assert marker.node_id == token.node_id

    assert marker.href ==
             "/day?date=" <> Date.to_iso8601(DateTime.to_date(appointment.scheduled_at))
  end

  test "a real check-in — the engine's own broadcast — moves the marker", %{
    conn: conn,
    vet: vet,
    patient: patient
  } do
    appointment = book(patient, vet)
    Scheduling.record_weight!(patient, Decimal.new("5.0"), actor: @staff)

    {:ok, view, _html} = live(conn, "/flight")

    # The board's check-in path: the click completes the visit's CheckIn
    # work item through the engine, the token advances, and the engine
    # broadcasts the movement the flight view is watching for.
    {:ok, _appointment} =
      ClinicDemo.Visits.VisitFacade.check_in_task(
        %{record: appointment, action: :check_in, actor: @staff},
        "flight test"
      )

    assert_push_event(view, "flight_positions", %{positions: positions})
    # The CheckIn token was consumed; what is live now stands past it.
    refute Enum.any?(positions, &(&1.node_id == "CheckIn"))
  end

  # --- fixtures -----------------------------------------------------------------

  defp book(patient, vet) do
    appointment =
      Scheduling.book_appointment!(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          reason: "Flight check"
        },
        actor: @staff
      )

    Scheduling.get_appointment!(appointment.id)
  end

  defp instance_for(appointment) do
    Instance
    |> Ash.Query.filter(subject_id == ^appointment.id and status == :running)
    |> Ash.read_one!(authorize?: false)
  end

  defp live_token(instance) do
    ClinicDemo.Visits.Token
    |> Ash.Query.filter(instance_id == ^instance.id and status in [:active, :executing, :waiting])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read_one!(authorize?: false)
  end
end
