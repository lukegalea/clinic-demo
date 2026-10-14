defmodule ClinicDemo.Finance.ForecastTest do
  @moduledoc """
  The forecast math is pure — no Ash, no clock, no database — so these
  tests hold it to the contract that purity buys: the same inputs give the
  same numbers, forever, and every number's provenance (which tier of the
  fallback chain answered, on how many observations) is carried alongside
  it.
  """

  use ClinicDemo.DataCase, async: true

  alias ClinicDemo.Finance.Forecast

  # Fixed coordinates, so every assertion below reads against the same
  # week grid regardless of the day the suite runs.
  @today Date.new!(2026, 10, 14)

  defp row(type, clinician, weekday, outcome) do
    %{appointment_type_id: type, clinician_id: clinician, weekday: weekday, outcome: outcome}
  end

  defp visit(id, type, clinician, %Date{} = day, price) do
    %{
      id: id,
      appointment_type_id: type,
      clinician_id: clinician,
      scheduled_at: DateTime.new!(day, ~T[10:00:00], "Etc/UTC"),
      amount: Decimal.new(price)
    }
  end

  # A history that teaches one dense cell: {type_a, clinician_a, Monday} is
  # 3-of-4 completed; type_b's Mondays are 1-of-3; the clinic-wide rate is
  # 4-of-7. Deliberately small enough to verify every tally by hand.
  defp history do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    c1 = Ecto.UUID.generate()
    c2 = Ecto.UUID.generate()

    rows = [
      row(a, c1, 1, :completed),
      row(a, c1, 1, :completed),
      row(a, c1, 1, :completed),
      row(a, c1, 1, :cancelled),
      # Thin cell: two observations is below the gate, whatever the mix.
      row(a, c2, 2, :completed),
      row(a, c2, 2, :completed),
      row(b, c1, 1, :completed),
      row(b, c1, 1, :no_show),
      row(b, c1, 1, :cancelled),
      # Open visits teach nothing and land in no tally.
      row(b, c2, 3, :open),
      row(b, c2, 3, :open)
    ]

    %{rows: rows, a: a, b: b, c1: c1, c2: c2}
  end

  test "build_rates tallies terminal visits at every coarseness and counts out open ones" do
    %{rows: rows, a: a, c1: c1} = history()
    rates = Forecast.build_rates(rows)

    assert rates.cell[{a, c1, 1}] == %{completed: 3, cancelled: 1, no_show: 0}
    assert rates.type_weekday[{a, 1}] == %{completed: 3, cancelled: 1, no_show: 0}
    assert rates.weekday[1] == %{completed: 4, cancelled: 2, no_show: 1}
    assert rates.global == %{completed: 6, cancelled: 2, no_show: 1}

    # The open visits contributed nothing, anywhere: every tally together
    # holds exactly the nine terminal visits.
    assert Map.values(rates.cell) |> Enum.all?(&(&1.completed + &1.cancelled + &1.no_show <= 4))
    assert length(Map.values(rates.cell)) == 3
    assert rates.global |> Map.values() |> Enum.sum() == 9
  end

  test "completion_rate reads the dense cell first and reports its provenance" do
    %{rows: rows, a: a, c1: c1} = history()
    rates = Forecast.build_rates(rows)

    {rate, tier, observations} = Forecast.completion_rate(rates, a, c1, 1)
    assert Decimal.eq?(rate, Decimal.new(3) |> Decimal.div(Decimal.new(4)))
    assert tier == :cell
    assert observations == 4
  end

  test "a cell below the observation gate falls through, not through with a 1-for-1" do
    %{rows: rows, a: a, b: b, c2: c2} = history()
    rates = Forecast.build_rates(rows)

    # {a, c2, Tuesday} saw only two terminal visits — too thin to trust.
    # The chain falls through the equally thin {a, Tuesday} to the type
    # tier, which holds type a's six observations: 5 completed of 6.
    {rate, tier, observations} = Forecast.completion_rate(rates, a, c2, 2)
    assert tier == :type
    assert observations == 6
    assert Decimal.eq?(rate, Decimal.new(5) |> Decimal.div(Decimal.new(6)))

    # Nothing anywhere for b on a Tuesday: type_weekday is empty (b's
    # terminal visits are all Mondays), so the type tier answers — 1 of 3.
    {rate, tier, observations} = Forecast.completion_rate(rates, b, c2, 2)
    assert tier == :type
    assert observations == 3
    assert Decimal.eq?(rate, Decimal.new(1) |> Decimal.div(Decimal.new(3)))
  end

  test "the clinic-wide cell is the floor the chain cannot fall below" do
    rates = Forecast.build_rates([row(Ecto.UUID.generate(), Ecto.UUID.generate(), 4, :no_show)])

    {rate, tier, observations} =
      Forecast.completion_rate(rates, Ecto.UUID.generate(), Ecto.UUID.generate(), 5)

    assert tier == :global
    assert observations == 1
    assert Decimal.eq?(rate, Decimal.new(0))

    # And an empty book floors at zero on zero observations.
    {rate, tier, observations} = Forecast.completion_rate(Forecast.build_rates([]), Ecto.UUID.generate(), Ecto.UUID.generate(), 1)
    assert {rate, tier, observations} == {Decimal.new(0), :global, 0}
  end

  test "weekly buckets Monday-anchored, weights by rate, and ignores the horizon's outside" do
    %{rows: rows, a: a, c1: c1} = history()
    rates = Forecast.build_rates(rows)

    # @today is Wednesday 2026-10-14, so this week starts Monday 10-12.
    this_week = Date.new!(2026, 10, 12)
    next_week = Date.new!(2026, 10, 19)

    scheduled = [
      visit("v1", a, c1, this_week, "100"),
      visit("v2", a, c1, this_week, "50"),
      visit("v3", a, c1, next_week, "200"),
      # Five weeks out — outside the four-week window entirely.
      visit("v4", a, c1, Date.add(this_week, 35), "999"),
      # Last week — someone's clock moved; not part of the claim.
      visit("v5", a, c1, Date.add(this_week, -7), "999")
    ]

    [week1, week2, _week3, _week4] = weeks = Forecast.weekly(scheduled, rates, @today)

    # v1 and v2 both read the dense cell: 0.75 × (100 + 50) = 112.50.
    assert week1.week_start == this_week
    assert Decimal.eq?(week1.expected, Decimal.new("112.50"))
    assert week1.scheduled_count == 2
    assert week1.tiers == %{cell: 2}

    # v3 reads the same cell on the same Monday key: 0.75 × 200 = 150.00.
    assert week2.week_start == next_week
    assert Decimal.eq?(week2.expected, Decimal.new("150.00"))
    assert week2.scheduled_count == 1

    # Exactly four weeks, Monday-anchored, in order.
    assert length(weeks) == 4
    assert Enum.map(weeks, & &1.week_start) == Enum.map(0..3, &Date.add(this_week, 7 * &1))

    # Determinism: the same inputs, the same numbers.
    assert weeks == Forecast.weekly(scheduled, rates, @today)
    assert rates == Forecast.build_rates(rows)
  end

  test "an empty book forecasts a flat, honest zero" do
    rates = Forecast.build_rates([])

    weeks = Forecast.weekly([], rates, @today)

    assert length(weeks) == 4
    assert Enum.all?(weeks, &Decimal.eq?(&1.expected, Decimal.new("0.00")))
  end

  test "rate_table carries the names and the clinic-wide row" do
    %{rows: rows, a: a, b: b} = history()
    rates = Forecast.build_rates(rows)

    table = Forecast.rate_table(rates, %{a => "Wellness exam", b => "Nail trim"})

    assert [%{name: "Nail trim"}, %{name: "Wellness exam"}, %{name: "All visits (clinic-wide)"}] = table

    wellness = Enum.find(table, &(&1.name == "Wellness exam"))
    assert wellness.completed == 5
    assert wellness.total == 7
    assert Decimal.eq?(wellness.rate, Decimal.new(5) |> Decimal.div(Decimal.new(7)))
  end
end
