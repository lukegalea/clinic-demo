defmodule ClinicDemoWeb.DayLiveTest do
  @moduledoc """
  The Day view's day split: a visit from earlier today folds into the
  native `<details>` "Earlier today" collapse. The seeds plant one such
  visit (booked through the attributed action, then slotted into today's
  tail with Ash.Seed, because NotInThePast guards :book and :reschedule);
  these tests prove what the seeds' visit exercises on every boot — the
  collapse renders with the real past item, opens its detail sheet like
  any upcoming row, and a day without history renders no collapse at all.
  """

  use ClinicDemoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ClinicDemo.Scheduling

  # A UUID, because booking starts a visit process and the instance records
  # who started it in a uuid column.
  @staff %{id: "00000000-0000-0000-0000-0000000000cc", role: :veterinarian}

  defp fixtures do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Day Test",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "Fold Test Animal",
          species: :dog,
          owner_email: "day-fold-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    %{vet: vet, patient: patient}
  end

  defp book_at(patient, vet, scheduled_at, reason) do
    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: scheduled_at,
          duration_minutes: 20,
          reason: reason,
          severity: 2
        },
        actor: @staff
      )

    appointment
  end

  # The lifecycle refuses past slots, so the earlier-today visit is booked
  # like any other and then moved with Ash.Seed — the same two-step the
  # seeds perform. Two hours back, clamped into today so a run just after
  # midnight still lands inside the selected day.
  defp plant_earlier_today_visit(patient, vet, reason) do
    appointment = book_at(patient, vet, DateTime.add(DateTime.utc_now(), 1, :day), reason)

    earlier_today =
      DateTime.utc_now()
      |> DateTime.add(-2 * 60 * 60)
      |> DateTime.truncate(:second)
      |> then(fn candidate ->
        if DateTime.to_date(candidate) == Date.utc_today() do
          candidate
        else
          DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
        end
      end)

    Ash.Seed.update!(appointment, %{scheduled_at: earlier_today})
  end

  test "an earlier-today visit folds into the Earlier today collapse", %{conn: conn} do
    %{vet: vet, patient: patient} = fixtures()

    past_visit = plant_earlier_today_visit(patient, vet, "Morning ear recheck")

    tomorrow =
      book_at(patient, vet, DateTime.add(DateTime.utc_now(), 1, :day), "Afternoon booking")

    {:ok, view, html} = live(conn, ~p"/day")

    # Today: the day's count is the selected day's alone — one visit, the
    # past one, inside the fold. Tomorrow's booking is not on this page.
    assert html =~ "1 appointments"
    assert html =~ "Earlier today (1)"
    assert html =~ "Morning ear recheck"
    refute html =~ "Afternoon booking"

    # The folded half is real content, not a stub: its row still opens the
    # read-only detail sheet, exactly like an upcoming row does.
    assert view
           |> element("nb-item[phx-value-id='#{past_visit.id}']")
           |> render_click() =~ "Read-only"

    # The fold is per-day: picking tomorrow renders no collapse and shows
    # that day's own visit.
    render_click(view, "select_day", %{
      "date" => Date.to_iso8601(DateTime.to_date(tomorrow.scheduled_at))
    })

    rendered = render(view)
    assert rendered =~ "Afternoon booking"
    refute rendered =~ "Earlier today"
  end

  test "a day with no earlier visits renders no collapse", %{conn: conn} do
    %{vet: vet, patient: patient} = fixtures()

    tomorrow = book_at(patient, vet, DateTime.add(DateTime.utc_now(), 1, :day), "Tomorrow only")

    {:ok, view, html} = live(conn, ~p"/day")

    # Today is empty (the booking is tomorrow's), so no collapse — and the
    # calendar's pick makes tomorrow's visit visible, without a fold.
    refute html =~ "Earlier today"

    render_click(view, "select_day", %{
      "date" => Date.to_iso8601(DateTime.to_date(tomorrow.scheduled_at))
    })

    rendered = render(view)
    assert rendered =~ "Tomorrow only"
    refute rendered =~ "Earlier today"
  end
end
