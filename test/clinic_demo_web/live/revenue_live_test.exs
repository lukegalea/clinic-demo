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

  # ── BD-4: the past scrubber ─────────────────────────────────────────────

  defp days_ago(days),
    do: DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

  # The seeds' walk at test scale, back-dated: booked 40 days ago for a
  # slot 15 days ago, triaged 14 days ago, checked in 10.5 days ago,
  # written up 10 days ago. The engine's triage (inside the booking) emits
  # no ledger event for a back-dated booking — the walk's own re-assert
  # lands at the story instant (the BD-3 ruling).
  defp back_dated_completed_visit(patient, vet, type) do
    booked_at = days_ago(40)
    triaged_at = days_ago(14)
    checked_in_at = days_ago(10) |> DateTime.add(-1800, :second)
    completed_at = days_ago(10)

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          appointment_type_id: type && type.id,
          scheduled_at: days_ago(15),
          duration_minutes: 30,
          reason: "Scrub walk",
          severity: 2
        },
        actor: @staff,
        as_of: booked_at
      )

    version = Scheduling.get_appointment!(appointment.id, as_of: triaged_at)
    Scheduling.record_appointment_triage!(version, :urgent, actor: @staff, as_of: triaged_at)

    Scheduling.record_weight(patient, Decimal.new("5.0"), actor: @staff)

    version = Scheduling.get_appointment!(appointment.id, as_of: checked_in_at)
    Scheduling.check_in_appointment!(version, actor: @staff, as_of: checked_in_at)

    version = Scheduling.get_appointment!(appointment.id, as_of: completed_at)
    Scheduling.complete_appointment!(version, "Scrubbed write-up.", actor: @staff, as_of: completed_at)

    appointment
  end

  test "scrubbing to a mid-history instant pins the money, the KPIs and the read-only posture", %{
    conn: conn
  } do
    %{vet: vet, patient: patient, type: type} = fixtures()

    # One visit written up ten days ago, one written up now: at rest the
    # page shows both; at the mid-history instant only the older one
    # existed, and the page must say so.
    back_dated_completed_visit(patient, vet, type)

    appointment = book(patient, vet, type, DateTime.add(DateTime.utc_now(), 1, :day))
    appointment = Scheduling.check_in_appointment!(appointment, actor: @staff)
    Scheduling.complete_appointment!(appointment, "Fresh write-up.", actor: @staff)

    ValueProjector.drain(:clinic)

    # At rest: the live page — both recognitions, the green chip.
    {:ok, view, html} = live(conn, ~p"/revenue")
    assert html =~ "$240"
    assert html =~ "2 charges"
    assert html =~ "Live now"

    # Sampled instants across the visit's history: at five days back only
    # the older recognition existed; at twenty days back the visit was
    # still open and nothing had been recognized.
    for {instant, expected_total, expected_count} <- [
          {days_ago(5), "$120", "1 charges"},
          {days_ago(20), "$0", "0 charges"}
        ] do
      iso = DateTime.to_iso8601(instant)

      assert html = render_patch(view, "?as_of=#{iso}")
      assert html =~ ~s(data-testid="revenue-as-of-indicator")
      assert html =~ "Viewing as of"
      assert html =~ "read-only"

      # The sampled instant's own numbers, money and count.
      assert html =~ expected_total
      assert html =~ expected_count

      # The time-travel card wears the traveling fill (violet) while a
      # live page wears the quiet one.
      assert html =~ "View revenue as of"
    end

    # The live chip's instant-classification: a write that the scrub says
    # is read-only offers no actions — the page is views all the way down.
    html = render_patch(view, "?as_of=#{DateTime.to_iso8601(days_ago(5))}")
    refute html =~ "check in"
    refute html =~ "Complete visit"

    # Back to the present: the URL drops the param and the page is the
    # live page again.
    assert html = render_patch(view, "?as_of=")
    assert html =~ "$240"
    assert html =~ "Live now"
  end

  test "a deep link mounts pinned at the instant", %{conn: conn} do
    %{vet: vet, patient: patient, type: type} = fixtures()

    back_dated_completed_visit(patient, vet, type)
    ValueProjector.drain(:clinic)

    mid_history = days_ago(5)

    {:ok, _view, html} = live(conn, "/revenue?as_of=#{DateTime.to_iso8601(mid_history)}")

    assert html =~ ~s(data-testid="revenue-as-of-indicator")
    assert html =~ "read-only"
    assert html =~ "$120"
    refute html =~ "$240"
  end

  test "an unparseable as_of reads as the present — the board's convention", %{conn: conn} do
    %{vet: vet, patient: patient, type: type} = fixtures()

    back_dated_completed_visit(patient, vet, type)
    ValueProjector.drain(:clinic)

    {:ok, view, html} = live(conn, ~p"/revenue")
    assert html =~ "Live now"

    # Garbage in the URL cannot be pinned, so it means the present — and
    # the URL is left where it is.
    assert html = render_patch(view, "?as_of=not-a-timestamp")
    assert html =~ "Live now"
    assert html =~ "$120"
  end
end
