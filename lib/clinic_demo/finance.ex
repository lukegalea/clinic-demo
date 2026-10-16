defmodule ClinicDemo.Finance do
  @moduledoc """
  The clinic's money: charges recognized by completed visits, and the reads
  the revenue view is built on.

  One resource today — `Finance.Charge`, recognized by an after-action hook
  on `Appointment.complete` (same transaction, same `as_of` instant). This
  module is also the context layer for the feature: the code interface the
  hook and the surfaces call, plus the read helpers that turn the temporal
  stores into the plain rows `Finance.Forecast` and `RevenueLive` consume.
  The helpers are ordinary Ash reads — no raw SQL — grouped in Elixir, which
  at the demo's scale (a few thousand rows) is simpler and honest.

  Revenue-at-T is an as-of read, exactly like the board's time travel: a
  charge exists from its `recognized_at` (its period's lower bound) onward,
  so `list_charges(as_of: t)` answers "what had the clinic recognized by
  instant t".
  """

  use Ash.Domain

  require Ash.Query

  alias ClinicDemo.BusinessEvents
  alias ClinicDemo.BusinessEvents.ValueProjection
  alias ClinicDemo.Finance.Charge
  alias ClinicDemo.Scheduling.Appointment

  resources do
    resource ClinicDemo.Finance.Charge do
      define :list_charges, action: :read
      define :get_charge, action: :read, get_by: [:id]
      define :recognize_charge, action: :recognize
      define :write_off_charge, action: :write_off
    end
  end

  @doc """
  Recognized revenue by calendar month: the paid charges whose
  `recognized_at` falls in each of the last `months` calendar months,
  oldest first. The running month counts — a partial month is shown as
  one, the way the clinic actually experiences it.

  Read as of now (or `as_of:` when the equivalence gate and the scrubber
  pin an instant), so a charge back-dated by the seeds sits in the month
  its recognition took effect at. A month with no charges still gets a
  row (zero total), so the chart's x-axis does not depend on the data's
  shape.

  This is one of the two derivations the equivalence gate pins (BD-3):
  the projection-derived `value_by_month/1` must agree with this, month
  for month, at every sampled instant.
  """
  @spec revenue_by_month(pos_integer(), keyword()) :: [
          %{month: Date.t(), total: Decimal.t(), count: non_neg_integer()}
        ]
  def revenue_by_month(months, opts \\ []) when is_integer(months) and months > 0 do
    # Descending explicitly — a bare `(months - 1)..0` reads as a warning
    # under Elixir 1.20's range rules.
    month_starts =
      for offset <- Range.new(months - 1, 0, -1) do
        Date.utc_today() |> Date.beginning_of_month() |> shift_month(-offset)
      end

    window_start = DateTime.new!(hd(month_starts), ~T[00:00:00], "Etc/UTC")

    query =
      Charge
      |> Ash.Query.filter(status == :paid and recognized_at >= ^window_start)

    query =
      case Keyword.get(opts, :as_of) do
        %DateTime{} = as_of -> Ash.Query.as_of(query, as_of)
        _absent_or_nil -> query
      end

    charges = Ash.read!(query, authorize?: false)

    month_windows(month_starts, Enum.map(charges, &{&1.recognized_at, &1.amount}))
  end

  @doc """
  The projection-derived twin of `revenue_by_month/2` (BD-3): the same
  month windows, computed over `ValueProjection` rows read as of the same
  instant — completed visits with a recognized amount and no write-off,
  which is exactly the charge-derived side's `status == :paid` filter,
  one fold over the ledger's truth.

  The equivalence gate (`BusinessEventsProjectionTest`) pins these two
  derivations to each other at sampled instants; `/revenue` reads this
  one, the charges remain the audit's own derivation.
  """
  @spec value_by_month(keyword()) :: [
          %{month: Date.t(), total: Decimal.t(), count: non_neg_integer()}
        ]
  def value_by_month(opts \\ []) do
    months = Keyword.get(opts, :months, 7)
    as_of = Keyword.get(opts, :as_of) || DateTime.utc_now()

    month_starts =
      for offset <- Range.new(months - 1, 0, -1) do
        Date.utc_today() |> Date.beginning_of_month() |> shift_month(-offset)
      end

    window_start = DateTime.new!(hd(month_starts), ~T[00:00:00], "Etc/UTC")

    rows =
      ValueProjection
      |> Ash.Query.filter(
        outcome == :completed and not is_nil(recognized_amount) and
          is_nil(written_off_amount) and recognized_at >= ^window_start
      )
      |> Ash.Query.as_of(as_of)
      |> Ash.read!(authorize?: false)

    month_windows(month_starts, Enum.map(rows, &{&1.recognized_at, &1.recognized_amount}))
  end

  # The month windows both revenue derivations group into: one row per
  # month, oldest first, counting and summing the `{instant, amount}`
  # entries whose instant falls in the window. Datetimes order only
  # through `DateTime.compare/2` — the `</>=` operators compare the struct
  # maps by alphabetical key order, where `:day` outranks `:month` and
  # October 14th sorts past November 1st.
  defp month_windows(month_starts, entries) do
    for month <- month_starts do
      from = DateTime.new!(month, ~T[00:00:00], "Etc/UTC")
      to = DateTime.new!(shift_month(month, 1), ~T[00:00:00], "Etc/UTC")

      in_month =
        Enum.filter(entries, fn {instant, _amount} ->
          DateTime.compare(instant, from) != :lt and
            DateTime.compare(instant, to) == :lt
        end)

      total =
        Enum.reduce(in_month, Decimal.new(0), fn {_instant, amount}, acc ->
          Decimal.add(acc, amount)
        end)

      %{month: month, total: total, count: length(in_month)}
    end
  end

  # Calendar-month shift without third-party date libs: walk `months` month
  # boundaries from the first of `date`'s month. Negative goes back.
  defp shift_month(%Date{} = date, months) do
    total = date.year * 12 + (date.month - 1) + months
    year = div(total, 12)
    month = rem(total, 12) + 1
    %Date{year: year, month: month, day: 1}
  end

  @doc """
  The lifecycle outcomes behind the forecast's rates: every appointment with
  a catalogue type, as plain rows.

  A row carries the three dimensions a rate cell is keyed on (type,
  clinician, weekday) plus which state the visit reached — `:completed`,
  `:cancelled`, `:no_show`, or `:open` (still ahead of us, so it has no
  outcome to teach the forecast yet).
  """
  @spec historical_outcomes(keyword()) :: [
          %{
            appointment_type_id: Ecto.UUID.t(),
            clinician_id: Ecto.UUID.t(),
            weekday: 1..7,
            outcome: :completed | :cancelled | :no_show | :open
          }
        ]
  def historical_outcomes(opts \\ []) do
    query =
      Appointment
      |> Ash.Query.filter(not is_nil(appointment_type_id))

    query =
      case Keyword.fetch(opts, :since) do
        {:ok, %DateTime{} = since} -> Ash.Query.filter(query, scheduled_at >= ^since)
        :error -> query
      end

    query
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn appointment ->
      %{
        appointment_type_id: appointment.appointment_type_id,
        clinician_id: appointment.clinician_id,
        weekday: Date.day_of_week(DateTime.to_date(appointment.scheduled_at)),
        outcome: outcome(appointment)
      }
    end)
  end

  @doc """
  The projection-derived twin of `historical_outcomes/1` (BD-3): the same
  `%{appointment_type_id, clinician_id, weekday, outcome}` rows the rates
  table and the forecast learn from, folded out of `ValueProjection`
  as of the instant (now, unless pinned). Visits without a catalogue type
  are excluded — the same filter the appointment-side read applies.
  """
  @spec projected_outcomes(keyword()) :: [
          %{
            appointment_type_id: Ecto.UUID.t(),
            clinician_id: Ecto.UUID.t(),
            weekday: 1..7,
            outcome: :completed | :cancelled | :no_show | :open
          }
        ]
  def projected_outcomes(opts \\ []) do
    as_of = Keyword.get(opts, :as_of) || DateTime.utc_now()

    ValueProjection
    |> Ash.Query.filter(not is_nil(type_id))
    |> Ash.Query.as_of(as_of)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn row ->
      %{
        appointment_type_id: row.type_id,
        clinician_id: row.clinician_id,
        weekday: Date.day_of_week(DateTime.to_date(row.scheduled_at)),
        outcome: row.outcome
      }
    end)
  end

  defp outcome(%{status: :completed}), do: :completed
  defp outcome(%{status: :cancelled}), do: :cancelled
  defp outcome(%{status: :no_show}), do: :no_show
  defp outcome(%{status: _in_flight}), do: :open

  @doc """
  The forecast's positive side: every appointment still `:scheduled` in the
  next `weeks` weeks, with its type (and so its price) resolved.

  `amount` is the price the visit would recognize on completion — read from
  the catalogue now, the same place a real completion would snapshot from.

  With `as_of:` the read pins to the instant (the schedule as it read at T —
  the retro-forecast the scrubbed page shows): the window anchors at T and
  the statuses are the temporal containment read. Without it, the live
  window from now — the exact pre-BD-4 path.
  """
  @spec scheduled_with_prices(pos_integer(), keyword()) :: [
          %{
            id: Ecto.UUID.t(),
            appointment_type_id: Ecto.UUID.t(),
            clinician_id: Ecto.UUID.t(),
            scheduled_at: DateTime.t(),
            amount: Decimal.t()
          }
        ]
  def scheduled_with_prices(weeks, opts \\ []) when is_integer(weeks) and weeks > 0 do
    now = Keyword.get(opts, :as_of) || DateTime.utc_now()
    horizon = DateTime.add(now, weeks * 7 * 24 * 3600, :second)

    query =
      Appointment
      |> Ash.Query.filter(
        status == :scheduled and scheduled_at >= ^now and scheduled_at < ^horizon
      )

    query =
      case Keyword.get(opts, :as_of) do
        %DateTime{} = as_of -> Ash.Query.as_of(query, as_of)
        _absent_or_nil -> query
      end

    query
    |> Ash.Query.load(:appointment_type)
    |> Ash.read!(authorize?: false)
    |> Enum.flat_map(fn appointment ->
      case appointment.appointment_type do
        %{base_price: price} = type ->
          [
            %{
              id: appointment.id,
              appointment_type_id: type.id,
              clinician_id: appointment.clinician_id,
              scheduled_at: appointment.scheduled_at,
              amount: price
            }
          ]

        nil ->
          []
      end
    end)
  end

  @doc """
  The one charge a visit recognizes, if it recognizes one. The recognition
  hook's idempotency check: a visit's history may walk `:complete` twice
  (the seeds' back-dated walk re-asserts the stage at the present), and the
  clinic charges for the visit, not for each retelling of it.
  """
  def charge_for(appointment_id) do
    Charge
    |> Ash.Query.filter(appointment_id == ^appointment_id)
    |> Ash.read_one!(authorize?: false)
  end

  @doc """
  The scenario overlay's read (BD-6): one simulation run's drawn
  completions, folded per Monday-anchored week — the same week shape
  `Forecast.weekly/3` plots, so real and simulated futures share one axis.

  **The read is the TWIN, not the sim projection, and the run label filters
  it** — the projection's grains are per-subject, so two runs over the same
  visit would straddle one grain; the run's own rows are its ground truth
  (BD-5's ruling, restated where the overlay needs it). `as_of:` caps the
  fold at "recognized BY T" (completions whose drawn instant has passed by
  T); without it the run's full horizon folds — the overlay's complete
  answer.

  Options:

    * `:as_of` — the cursor instant capping the fold (nil: full horizon).
    * `:weeks` — how many Monday-anchored horizon weeks to emit (default
      4, the forecast's own horizon; a completion spilling past the last
      week opens a trailing week, per the generator's own folding).

  Returns `%{weeks: [%{week_start, week_end, recognized, completions}],
  horizon_expected, recognized_to_t, remaining_after_t}` — the overlay's
  polyline and the SIM-mode KPIs, from one read.
  """
  @spec sim_run_summary(String.t(), keyword()) :: %{
          weeks: [
            %{
              week_start: Date.t(),
              week_end: Date.t(),
              recognized: Decimal.t(),
              completions: non_neg_integer()
            }
          ],
          horizon_expected: Decimal.t(),
          recognized_to_t: Decimal.t(),
          remaining_after_t: non_neg_integer()
        }
  def sim_run_summary(run, opts \\ []) when is_binary(run) do
    as_of = Keyword.get(opts, :as_of)
    horizon_weeks = Keyword.get(opts, :weeks, 4)
    today = Date.utc_today()

    # One read of the run's own rows: completions carry the money, every
    # outcome counts toward "remaining after T".
    drawn =
      BusinessEvents.Ledger.SimulationEvent
      |> Ash.Query.filter(simulation_run == ^run)
      |> Ash.Query.sort(:sequence)
      |> Ash.read!(authorize?: false)

    completions =
      drawn
      |> Enum.filter(&(&1.action == :visit_completed))
      |> Enum.map(&{&1.occurred_at, parse_amount(&1.data["amount"])})

    within_t = fn %DateTime{} = at ->
      is_nil(as_of) or DateTime.compare(at, as_of) != :gt
    end

    horizon_starts =
      for offset <- 0..(horizon_weeks - 1) do
        today |> Date.beginning_of_week() |> Date.add(7 * offset)
      end

    %{
      weeks:
        week_buckets(horizon_starts, Enum.filter(completions, fn {at, _} -> within_t.(at) end)),
      horizon_expected:
        completions
        |> Enum.reduce(Decimal.new(0), fn {_at, amount}, acc -> Decimal.add(acc, amount) end)
        |> Decimal.round(2),
      recognized_to_t:
        completions
        |> Enum.filter(fn {at, _} -> within_t.(at) end)
        |> Enum.reduce(Decimal.new(0), fn {_at, amount}, acc -> Decimal.add(acc, amount) end)
        |> Decimal.round(2),
      remaining_after_t: Enum.count(drawn, fn e -> not within_t.(e.occurred_at) end)
    }
  end

  defp parse_amount(nil), do: Decimal.new(0)
  defp parse_amount(%Decimal{} = amount), do: amount
  defp parse_amount(amount) when is_binary(amount), do: Decimal.new(amount)

  # The Monday-anchored horizon weeks, each summing the completions whose
  # drawn instant falls in the week. A completion past the horizon's last
  # week opens a trailing week, like the generator's own folding.
  defp week_buckets(horizon_starts, completions) do
    empty = %{week_start: nil, week_end: nil, recognized: Decimal.new(0), completions: 0}

    horizon_starts
    |> Map.new(fn week_start ->
      {week_start, %{empty | week_start: week_start, week_end: Date.add(week_start, 6)}}
    end)
    |> then(fn buckets ->
      Enum.reduce(completions, buckets, fn {at, amount}, buckets ->
        week_start = at |> DateTime.to_date() |> Date.beginning_of_week()

        bucket =
          Map.get_lazy(buckets, week_start, fn ->
            %{empty | week_start: week_start, week_end: Date.add(week_start, 6)}
          end)

        bucket
        |> Map.update!(:recognized, &Decimal.add(&1, amount))
        |> Map.update!(:completions, &(&1 + 1))
        |> then(&Map.put(buckets, week_start, &1))
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.week_start, &(Date.compare(&1, &2) != :gt))
    |> Enum.map(&Map.update!(&1, :recognized, fn total -> Decimal.round(total, 2) end))
  end
end
