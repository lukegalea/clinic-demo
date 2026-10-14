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
          license_number: "ON-#{System.unique_integer([:positive])}"
        },
        actor: @staff
      )

    {:ok, _nurse} =
      Scheduling.hire_clinician(
        %{
          full_name: "Seed Front Desk",
          role: :nurse,
          license_number: "VN-#{System.unique_integer([:positive])}"
        },
        actor: @staff
      )
  end

  defp count_charge_total do
    Charge |> Ash.read!(authorize?: false) |> length()
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
