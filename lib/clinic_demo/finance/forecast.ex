defmodule ClinicDemo.Finance.Forecast do
  @moduledoc """
  The forecast math, and nothing but the forecast math: pure functions over
  plain rows, no Ash, no clock, no database. Everything time-shaped is an
  argument, which is what makes it deterministically testable — the same
  inputs give the same numbers, forever.

  The model, stated plainly:

    * History teaches a **completion rate**: of the past visits that reached
      a terminal state (completed, cancelled, no-show), what share actually
      happened. Visits still ahead of us teach nothing yet and are excluded.
    * A rate is keyed on the three dimensions the clinic actually varies in
      — **type, clinician, weekday** — and read through a fallback chain
      when a cell is too thin to trust: `{type, clinician, weekday}` →
      `{type, weekday}` → `{type, any day}` → `{any type, weekday}` → the
      clinic-wide base rate. A cell must have observed at least
      `@min_observations` terminal visits before it is consulted at all;
      below that the lookup falls through rather than trusting a 1-for-1.
    * A future scheduled visit contributes `rate × price` — its completion
      probability times the amount it would recognize. Summed per week,
      that is the forecast line: expected revenue per week for the next
      `@weeks` weeks, each week bucketed from Monday.
    * Every number carries its **confidence inputs** — how many scheduled
      visits resolved at which tier of the chain, and how many terminal
      observations back each cell. A forecast is a claim about evidence;
      the evidence ships with it.
  """

  @weeks 4

  # A rate cell needs this many terminal visits before the chain consults
  # it; below that, a single fluke would read as a 100% (or 0%) completion
  # rate and skew every visit it keys.
  @min_observations 3

  @typedoc "A terminal-outcome tally: the three states a finished visit ends in."
  @type outcome_counts :: %{required(:completed | :cancelled | :no_show) => non_neg_integer()}

  @typedoc "One history row, as `Finance.historical_outcomes/1` emits them."
  @type outcome_row :: %{
          appointment_type_id: Ecto.UUID.t(),
          clinician_id: Ecto.UUID.t(),
          weekday: 1..7,
          outcome: :completed | :cancelled | :no_show | :open
        }

  @typedoc "One future row, as `Finance.scheduled_with_prices/1` emits them."
  @type scheduled_row :: %{
          id: Ecto.UUID.t(),
          appointment_type_id: Ecto.UUID.t(),
          clinician_id: Ecto.UUID.t(),
          scheduled_at: DateTime.t(),
          amount: Decimal.t()
        }

  @typedoc "The rate table: outcome tallies keyed at five coarsenesses."
  @type rates :: %{
          cell: %{optional({Ecto.UUID.t(), Ecto.UUID.t(), 1..7}) => outcome_counts()},
          type_weekday: %{optional({Ecto.UUID.t(), 1..7}) => outcome_counts()},
          type: %{optional(Ecto.UUID.t()) => outcome_counts()},
          weekday: %{optional(1..7) => outcome_counts()},
          global: outcome_counts()
        }

  @typedoc "Where in the fallback chain a visit's rate came from."
  @type tier :: :cell | :type_weekday | :type | :weekday | :global

  @doc """
  Builds the rate table from `Finance.historical_outcomes/1` rows. Open
  visits are counted toward nothing; every terminal visit lands in all five
  coarsenesses it belongs to.
  """
  @spec build_rates([outcome_row(), ...]) :: rates()
  def build_rates(rows) do
    terminal = Enum.filter(rows, &(&1.outcome in [:completed, :cancelled, :no_show]))

    empty = %{completed: 0, cancelled: 0, no_show: 0}

    add = fn tallies, key, row ->
      Map.update(tallies, key, Map.put(empty, row.outcome, 1), fn counts ->
        Map.update!(counts, row.outcome, &(&1 + 1))
      end)
    end

    %{
      cell:
        Enum.reduce(
          terminal,
          %{},
          &add.(&2, {&1.appointment_type_id, &1.clinician_id, &1.weekday}, &1)
        ),
      type_weekday:
        Enum.reduce(terminal, %{}, &add.(&2, {&1.appointment_type_id, &1.weekday}, &1)),
      type: Enum.reduce(terminal, %{}, &add.(&2, &1.appointment_type_id, &1)),
      weekday: Enum.reduce(terminal, %{}, &add.(&2, &1.weekday, &1)),
      global:
        Enum.reduce(terminal, empty, fn row, counts ->
          Map.update!(counts, row.outcome, &(&1 + 1))
        end)
    }
  end

  @doc """
  The completion probability for one visit's dimensions, read through the
  fallback chain. Returns `{probability, tier, observations}` — the share of
  terminal visits that completed, where the answer came from, and how many
  observations back it. Only the clinic-wide cell is always present, so a
  `{:global, _, _}` answer is the floor the chain cannot fall below.
  """
  @spec completion_rate(rates(), Ecto.UUID.t(), Ecto.UUID.t(), 1..7) ::
          {Decimal.t(), tier(), non_neg_integer()}
  def completion_rate(rates, type_id, clinician_id, weekday) do
    [
      {:cell, Map.get(rates.cell, {type_id, clinician_id, weekday})},
      {:type_weekday, Map.get(rates.type_weekday, {type_id, weekday})},
      {:type, Map.get(rates.type, type_id)},
      {:weekday, Map.get(rates.weekday, weekday)},
      {:global, rates.global}
    ]
    |> Enum.find_value(fn
      {tier, counts} ->
        case completed_share(counts) do
          nil -> nil
          {rate, observations} -> {rate, tier, observations}
        end
    end)
    |> case do
      nil -> {Decimal.new(0), :global, 0}
      {rate, tier, observations} -> {rate, tier, observations}
    end
  end

  # completed / (completed + cancelled + no_show), as a decimal. The
  # min-observations gate lives here: a thinner cell reads as absent, and
  # the chain falls through.
  defp completed_share(counts) do
    observations = counts.completed + counts.cancelled + counts.no_show

    if observations >= @min_observations do
      {Decimal.div(Decimal.new(counts.completed), Decimal.new(observations)), observations}
    else
      nil
    end
  end

  @doc """
  The weekly projection: expected revenue for the next `#{@weeks}` weeks,
  Monday-anchored, from the future scheduled visits and the rate table.

  Each week carries its total, the number of scheduled visits that went
  into it, and the confidence inputs — how many visits resolved at which
  tier, and the total observations backing the cells they used. The first
  bucket is the week `today` is already part of (its earlier days are
  history now, but the bucket is the week, not the remainder).
  """
  @spec weekly([scheduled_row()], rates(), Date.t()) :: [
          %{
            week_start: Date.t(),
            week_end: Date.t(),
            expected: Decimal.t(),
            scheduled_count: non_neg_integer(),
            tiers: %{optional(tier()) => non_neg_integer()},
            observations: non_neg_integer()
          }
        ]
  def weekly(scheduled, rates, today) do
    week_starts =
      for offset <- 0..(@weeks - 1) do
        today |> Date.beginning_of_week() |> Date.add(7 * offset)
      end

    buckets =
      Map.new(week_starts, fn week_start ->
        {week_start,
         %{
           week_start: week_start,
           week_end: Date.add(week_start, 6),
           expected: Decimal.new(0),
           scheduled_count: 0,
           tiers: %{},
           observations: 0
         }}
      end)

    scheduled
    |> Enum.reduce(buckets, fn visit, buckets ->
      week_start =
        visit.scheduled_at
        |> DateTime.to_date()
        |> Date.beginning_of_week()

      case Map.fetch(buckets, week_start) do
        :error ->
          # Outside the horizon (or in the past — someone's clock moved):
          # not part of the forecast window, so not part of the claim.
          buckets

        {:ok, bucket} ->
          add_visit(rates, buckets, week_start, bucket, visit)
      end
    end)
    |> Enum.sort_by(& &1.week_start)
    |> Enum.map(fn bucket ->
      # Round once, at the bucket's edge: pennies are a presentation
      # decision, not an accumulation one.
      Map.update!(bucket, :expected, &Decimal.round(&1, 2))
    end)
  end

  # One scheduled visit's weighted contribution, folded into its week: the
  # completion rate its dimensions read from the chain, times the amount it
  # would recognize, plus the confidence inputs of the cell that answered.
  defp add_visit(rates, buckets, week_start, bucket, visit) do
    {rate, tier, observations} =
      completion_rate(
        rates,
        visit.appointment_type_id,
        visit.clinician_id,
        weekday(visit.scheduled_at)
      )

    bucket
    |> Map.update!(:expected, &Decimal.add(&1, Decimal.mult(rate, visit.amount)))
    |> Map.update!(:scheduled_count, &(&1 + 1))
    |> Map.update!(:tiers, &Map.update(&1, tier, 1, fn n -> n + 1 end))
    |> Map.update!(:observations, &(&1 + observations))
    |> then(&Map.put(buckets, week_start, &1))
  end

  @doc """
  The display half of the confidence story: one row per catalogue type with
  its observed terminal visits and completion share, plus the clinic-wide
  row. The rates table under the forecast line renders exactly this.
  """
  @spec rate_table(rates(), %{optional(Ecto.UUID.t()) => String.t()}) :: [
          %{
            name: String.t(),
            completed: non_neg_integer(),
            total: non_neg_integer(),
            rate: Decimal.t() | nil
          }
        ]
  def rate_table(rates, type_names) do
    type_rows =
      rates.type
      |> Enum.map(fn {type_id, counts} ->
        {share, observations} =
          case completed_share(counts) do
            nil -> {nil, 0}
            pair -> pair
          end

        %{
          name: Map.get(type_names, type_id, type_id),
          completed: counts.completed,
          total: observations,
          rate: share
        }
      end)
      |> Enum.sort_by(& &1.name)

    global =
      case completed_share(rates.global) do
        nil ->
          %{name: "All visits (clinic-wide)", completed: 0, total: 0, rate: nil}

        {share, observations} ->
          %{
            name: "All visits (clinic-wide)",
            completed: rates.global.completed,
            total: observations,
            rate: share
          }
      end

    type_rows ++ [global]
  end

  defp weekday(%DateTime{} = dt), do: Date.day_of_week(DateTime.to_date(dt))
end
