defmodule ClinicDemo.FinanceSeedsTest do
  @moduledoc """
  The finance seeds' two hard properties, at a small window: the world they
  write is real (bookings through the attributed actions, completions that
  recognize their charges), and a re-run costs nothing — the deterministic
  draws re-find every visit they booked, every visit is terminal or
  resumable, and the ledger does not move.
  """

  use ClinicDemo.DataCase, async: false

  require Ash.Query

  alias ClinicDemo.Finance
  alias ClinicDemo.Finance.Charge
  alias ClinicDemo.FinanceSeeds
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.Appointment

  # A UUID, because booking starts a visit process and the instance records
  # who acted in uuid columns.
  @staff %{id: "00000000-0000-0000-0000-0000000000ff", role: :veterinarian}

  # One Monday-to-Friday week of history and one week ahead, a handful of
  # visits a day: enough to exercise every walk, small enough to keep the
  # suite quick. The roster needs a nurse for the front-desk actor the
  # CheckIn tasks are closed with.
  @opts [weeks_back: 1, weeks_ahead: 1, weekday_per_day: 4, weekend_per_day: 2]

  defp hire_staff do
    {:ok, _vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Seed Vet",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, _nurse} =
      Scheduling.hire_clinician(
        %{
          full_name: "Seed Front Desk",
          role: :nurse,
          license_number: "VN-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )
  end

  defp count_charge_total do
    Charge |> Ash.read!(authorize?: false) |> length()
  end

  # The board reads the read instant's day and the next. Seeding "as if on"
  # `today` puts this module's only board-window day at `today + 1`; the
  # board read as of noon on `today` is what the board renders the morning
  # after such a seed. Projected to what a card shows — time of day,
  # patient, clinician, type, reason, severity, status, triage — so two
  # boards compare across dates.
  defp finance_board_as_of(today) do
    bench =
      Scheduling.Patient
      |> Ash.Query.filter(contains(owner_email, "fin."))
      |> Ash.read!(authorize?: false)
      |> MapSet.new(& &1.id)

    Appointment
    |> Ash.Query.for_read(:board, %{}, as_of: DateTime.new!(today, ~T[12:00:00], "Etc/UTC"))
    |> Ash.Query.load([:patient, :clinician, :appointment_type])
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&MapSet.member?(bench, &1.patient_id))
    |> Enum.map(fn appointment ->
      %{
        day_offset: Date.diff(DateTime.to_date(appointment.scheduled_at), today),
        time: DateTime.to_time(appointment.scheduled_at),
        patient: appointment.patient.name,
        clinician: appointment.clinician.full_name,
        type: appointment.appointment_type.name,
        reason: appointment.reason,
        severity: appointment.severity,
        status: appointment.status,
        triage_urgency: appointment.triage_urgency
      }
    end)
    |> Enum.sort_by(&{&1.day_offset, &1.time, &1.patient})
  end

  defp next_weekday(from, weekday),
    do: Date.add(from, rem(weekday - Date.day_of_week(from) + 7, 7))

  defp finance_visits_on(day) do
    from = DateTime.new!(day, ~T[00:00:00], "Etc/UTC")
    to = DateTime.add(from, 1, :day)

    Appointment
    |> Ash.Query.filter(scheduled_at >= ^from and scheduled_at < ^to)
    |> Ash.Query.filter(contains(patient.owner_email, "fin."))
    |> Ash.read!(authorize?: false)
    |> length()
  end

  # N8: the board's baseline moved with the weekday CI ran on, because the
  # board's one finance day (tomorrow) drew its volume and visits from its
  # calendar date. Seeded as if on a Wednesday and as if on a Saturday — in
  # the future, so the live window books at wall-now like the real run —
  # the two boards must be the same board. The windows (a week ahead each)
  # do not overlap, so neither run touches the other's board.
  test "the board shows the same finance visits whatever weekday the seed runs on" do
    hire_staff()

    wednesday = next_weekday(Date.add(Date.utc_today(), 30), 3)
    saturday = Date.add(wednesday, 10)
    assert Date.day_of_week(saturday) == 6

    opts = [weeks_back: 0, weeks_ahead: 1, weekday_per_day: 4, weekend_per_day: 2]

    FinanceSeeds.run(Keyword.put(opts, :today, wednesday))
    FinanceSeeds.run(Keyword.put(opts, :today, saturday))

    from_wednesday = finance_board_as_of(wednesday)
    from_saturday = finance_board_as_of(saturday)

    # Thursday's board day and Sunday's: a weekday and a weekend day, which
    # the date-keyed draw would have filled from different volume ranges.
    assert length(from_wednesday) == 7
    assert Enum.all?(from_wednesday, &(&1.day_offset == 1))
    assert from_wednesday == from_saturday
  end

  # The window slides: a re-run a day later finds yesterday's day-after as
  # its new board day, already booked by the date-keyed draw. It keeps
  # that draw (the one on file) rather than stacking the board day's seven
  # beside it.
  test "a re-run a day later keeps the day on file instead of stacking the board day on it" do
    hire_staff()

    today = Date.add(Date.utc_today(), 30)
    opts = [weeks_back: 0, weeks_ahead: 1, weekday_per_day: 4, weekend_per_day: 2]

    FinanceSeeds.run(Keyword.put(opts, :today, today))
    on_file = finance_visits_on(Date.add(today, 2))
    assert on_file > 0

    run2 = FinanceSeeds.run(Keyword.put(opts, :today, Date.add(today, 1)))

    assert finance_visits_on(Date.add(today, 2)) == on_file
    # Only the window's new last day was booked.
    assert run2.booked == finance_visits_on(Date.add(today, 8))
  end

  test "a re-run backfills nothing and moves no charge" do
    hire_staff()

    run1 = FinanceSeeds.run(@opts)

    assert run1.booked > 0
    assert run1.skipped == 0
    assert run1.completed > 0

    # Every history visit reached exactly one terminal outcome; the rest of
    # the bookings are the live window, still :scheduled for the forecast.
    terminal = run1.completed + run1.cancelled + run1.no_show

    future_scheduled =
      Appointment
      |> Ash.Query.filter(status == :scheduled and scheduled_at > ^DateTime.utc_now())
      |> Ash.read!(authorize?: false)
      |> length()

    assert terminal + future_scheduled == run1.booked

    # Every completion recognized exactly one charge, at a catalogue price.
    charges = Charge |> Ash.read!(authorize?: false)
    assert length(charges) == run1.completed

    catalogue_prices =
      Scheduling.list_appointment_types!(authorize?: false)
      |> Map.new(&{&1.id, &1.base_price})

    booked_types =
      Appointment
      |> Ash.Query.select([:id, :appointment_type_id])
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.id, &1.appointment_type_id})

    Enum.each(charges, fn charge ->
      assert price = catalogue_prices[booked_types[charge.appointment_id]]
      assert Decimal.eq?(charge.amount, price)
      assert charge.status == :paid
    end)

    charge_count = length(charges)

    # The re-run: same draws (the streams key on day and index alone), so
    # every visit is already on file and terminal — nothing booked, nothing
    # walked to completion again, no new money.
    run2 = FinanceSeeds.run(@opts)

    assert run2.booked == 0
    assert run2.skipped == run1.booked
    assert run2.completed == 0
    assert run2.cancelled == 0
    assert count_charge_total() == charge_count

    # And the history is where the walk left it: the as-of reads the
    # revenue view is built on still find the ledger.
    assert Finance.revenue_by_month(3)
           |> Enum.map(& &1.total)
           |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
           |> Decimal.gt?(Decimal.new(0))
  end
end
