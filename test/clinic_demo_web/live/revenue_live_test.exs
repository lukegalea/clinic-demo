defmodule ClinicDemoWeb.RevenueLiveTest do
  @moduledoc """
  The revenue page reads the whole book once per mount — the Day view's
  pattern — so these tests assert what a mount renders out of a small,
  hand-built ledger: a completed visit's charge lands in the month bars,
  the KPI row reports it, and a booked-but-unwritten visit sits in the
  forecast's scheduled count without having moved any revenue.
  """

  use ClinicDemoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClinicDemo.BusinessEvents.ValueProjector
  alias ClinicDemo.Finance.Charge
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.AppointmentType

  # A UUID, because booking starts a visit process and the instance records
  # who acted in uuid columns.
  @staff %{id: "00000000-0000-0000-0000-000000000044", role: :veterinarian}

  setup do
    # The page reads the value projection (BD-3's source swap); its events
    # only emit when the mapping rules are deployed — the seeds' install!
    # order, at test scale. (test_helper publishes the rules; the mappings
    # are this suite's own fixture.)
    ClinicDemo.BusinessEvents.install!()
    :ok
  end

  defp fixtures do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Revenue Test",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "Revenue Test Animal",
          species: :dog,
          owner_email: "revenue-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    type =
      AppointmentType
      |> Ash.Changeset.for_create(:create, %{
        name: "Revenue Test Exam #{System.unique_integer([:positive])}",
        base_price: Decimal.new(120),
        default_duration_minutes: 30
      })
      |> Ash.create!(authorize?: false)

    %{vet: vet, patient: patient, type: type}
  end

  defp book(patient, vet, type, scheduled_at) do
    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          appointment_type_id: type.id,
          scheduled_at: scheduled_at,
          duration_minutes: type.default_duration_minutes,
          reason: "Revenue walk",
          severity: 2
        },
        actor: @staff
      )

    appointment
  end

  test "a completed visit's charge shows in the month bars and the KPIs", %{conn: conn} do
    %{vet: vet, patient: patient, type: type} = fixtures()

    # One written-up visit: recognized revenue of $120.
    appointment = book(patient, vet, type, DateTime.add(DateTime.utc_now(), 1, :day))
    appointment = Scheduling.check_in_appointment!(appointment, actor: @staff)
    Scheduling.complete_appointment!(appointment, "Written up for the books", actor: @staff)

    # One still on the books for tomorrow: forecast material, no revenue.
    book(patient, vet, type, DateTime.add(DateTime.utc_now(), 2, :day))

    assert Charge |> Ash.read!(authorize?: false) |> length() == 1

    # The page reads the value projection (BD-3's source swap): fold the
    # events the walk just wrote before mounting it.
    ValueProjector.drain(:clinic)

    {:ok, _view, html} = live(conn, ~p"/revenue")

    # The page is the revenue page: its headline sections render.
    assert html =~ "Recognized revenue by month"
    assert html =~ "Forecast — next four weeks"

    # The ledger's one charge, in the KPI row and the chart.
    assert html =~ "$120"
    assert html =~ "1 charges"

    # The scheduled visit is counted for the forecast.
    assert html =~ "visits on the books"
  end

  test "an empty ledger renders a flat, honest zero", %{conn: conn} do
    fixtures()

    {:ok, _view, html} = live(conn, ~p"/revenue")

    assert html =~ "Recognized revenue by month"
    assert html =~ "$0"
  end
end
