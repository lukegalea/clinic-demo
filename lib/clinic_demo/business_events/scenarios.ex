defmodule ClinicDemo.BusinessEvents.Scenarios do
  @moduledoc """
  The future-scenario generator (BPSim design §2d, BPSim BD-5): the
  forecast's own completion rates, twisted by one multiplier knob, drawn
  deterministically into a labeled simulation run on the ledger's twin,
  and folded by the dedicated sim projector into the separate sim value
  projection.

  The mechanics, in order:

    1. Read `Finance.scheduled_with_prices/1` (every visit still ahead of
       us, with its catalogue price) and `Forecast.build_rates/1` (what
       history teaches about completion).
    2. Per visit: `p = clamp(rate × multiplier, 0, 1)`; sample `u` from a
       `:rand` stream seeded by `(visit_id, label)` ALONE — the
       FinanceSeeds determinism discipline. `u < p` → a simulated
       `visit.completed` at `scheduled_at + duration` with `amount: price`;
       otherwise a cancelled/no-show draw split along the clinic's observed
       terminal mix.
    3. Record each drawn outcome on `Ledger.SimulationEvent` — the twin —
       through the same active mappings the real moments use, with
       `simulation_run: label`, delivery key
       `"scenario:<label>:<appointment_id>:<outcome>"`, and a
       structural-only `context` (multiplier, rate, tier — no actor, no
       PII).
    4. `SimValueProjector.drain_simulation(label, :clinic)` folds the run
       into `SimValueProjection` — the separate table, never the real
       value projection (design risk #2).

  ## Determinism and idempotency

  The seed is `(visit_id, label)` alone — the multiplier does not enter
  it — so for a fixed label the same visit always draws the same `u`, and
  raising the multiplier can only turn non-completions into completions,
  never the reverse. Two knobs are two runs: the default label is
  content-addressed (`scenario:x<multiplier>-h<horizon>`), so regenerating
  with the same knobs lands on the same label, where every delivery key
  already exists and the second generation appends NOTHING — the run, its
  cursor and its periods are untouched. An explicit label takes the knobs
  out of the name; giving one label different multipliers over time would
  leave the first draw's rows standing (delivery keys are per outcome), so
  a changed assumption wants a changed label.

  The run's ground truth is the twin (the generator's weekly summary
  below folds the run's own completions); the projection serves the
  as-of(future-T) reads the overlay will make. Every instant here is
  future-dated by construction — the real ledger never holds a
  simulated event, at any instant.
  """

  require Ash.Query

  alias ClinicDemo.BusinessEvents.Ledger
  alias ClinicDemo.BusinessEvents.MappingVersion
  alias ClinicDemo.BusinessEvents.SimValueProjector
  alias ClinicDemo.Finance
  alias ClinicDemo.Finance.Forecast
  alias ClinicDemo.Scheduling.Appointment

  @region :clinic
  @residency "ca"
  @subject_type "clinic.visit"

  @default_multiplier Decimal.new("1.0")
  @default_horizon_weeks 4

  @completion :visit_completed
  @cancellation :visit_cancelled
  @no_show :visit_no_show

  @typedoc "One drawn outcome, ready to record on the twin."
  @type planned :: %{
          required(:appointment_id) => Ecto.UUID.t(),
          required(:run) => String.t(),
          required(:kind) => :visit_completed | :visit_cancelled | :visit_no_show,
          required(:occurred_at) => DateTime.t(),
          required(:amount) => Decimal.t() | nil,
          required(:rate) => Decimal.t(),
          required(:tier) => Forecast.tier(),
          required(:multiplier) => Decimal.t()
        }

  @doc """
  Generates one labeled simulation run over the visits still ahead of us
  and folds it into the sim value projection.

  ## Options

    * `:multiplier` — the completion-rate knob, clamped at the draw to
      `[0, 1]` per visit (`Decimal`, default `1.0`; the UI's range is
      0.0–1.5 step 0.05, and any decimal is honest input).
    * `:label` — the run's label (default: content-addressed from the
      knobs — see the moduledoc's determinism ruling).
    * `:horizon_weeks` — how far ahead the scenario reaches (default
      `#{@default_horizon_weeks}`, the forecast's own horizon).

  Returns the run's label, the run's total twin rows, how many outcomes
  this call drew and actually appended (a regeneration appends zero),
  and the run's completions folded per Monday-anchored week — the same
  week shape `Forecast.weekly/3` speaks, so the overlay can plot real
  and simulated futures on one axis.
  """
  @spec generate!(keyword()) :: %{
          run: String.t(),
          events: non_neg_integer(),
          generated: non_neg_integer(),
          appended: non_neg_integer(),
          weeks: [map()]
        }
  def generate!(opts \\ []) do
    multiplier = Keyword.get(opts, :multiplier, @default_multiplier)
    horizon_weeks = Keyword.get(opts, :horizon_weeks, @default_horizon_weeks)
    label = Keyword.get(opts, :label) || default_label(multiplier, horizon_weeks)

    scheduled = Finance.scheduled_with_prices(horizon_weeks)
    rates = Finance.historical_outcomes() |> Forecast.build_rates()

    visits =
      durations(Enum.map(scheduled, & &1.id))
      |> then(fn durations ->
        Enum.map(scheduled, &Map.put(&1, :duration_minutes, durations[&1.id]))
      end)

    planned = plan(visits, label, rates, multiplier)

    before = run_events(label)
    Enum.each(planned, &record!/1)
    SimValueProjector.drain_simulation(label, @region)
    after_count = run_events(label)

    %{
      run: label,
      events: after_count,
      generated: length(planned),
      appended: after_count - before,
      weeks: weeks(planned, horizon_weeks)
    }
  end

  @doc """
  The pure half of the generator — the draw, no ledger, no clock: plain
  visit rows in, drawn outcomes out. Determinism lives here: each visit's
  draw is seeded by `(visit_id, label)` alone, so the same rows, label
  and multiplier always produce the identical multiset, and a higher
  multiplier can only move a visit toward completion (the `u` never
  changes; only the bar it must clear does).

  Each visit row needs `:id`, `:appointment_type_id`, `:clinician_id`,
  `:scheduled_at`, `:amount` and `:duration_minutes` — the shape
  `Finance.scheduled_with_prices/1` emits plus the slot's length.
  """
  @spec plan([map()], String.t(), Forecast.rates(), Decimal.t()) :: [planned()]
  def plan(visits, label, rates, multiplier) do
    visits
    # Record order is commit order on the twin's chain: order by the
    # visit's id, not by whatever the read happened to return.
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&draw(&1, label, rates, multiplier))
  end

  @doc "The runs already on the twin, via the package's supported read (AC-3)."
  @spec runs() :: [map()]
  def runs, do: AshDiscreteBusinessEvents.simulation_runs(Ledger)

  # ── the draw ───────────────────────────────────────────────────────────

  defp draw(visit, label, rates, multiplier) do
    {rate, tier, _observations} =
      Forecast.completion_rate(
        rates,
        visit.appointment_type_id,
        visit.clinician_id,
        weekday(visit.scheduled_at)
      )

    p = clamp01(Decimal.mult(rate, multiplier))
    seed = :rand.seed_s(:exsss, seed_tuple(visit.id, label))
    {u, rest} = :rand.uniform_s(seed)

    outcome =
      if Decimal.lt?(Decimal.from_float(u), p) do
        @completion
      else
        # Not completed: the clinic's observed terminal mix splits the
        # rest between cancelled and no-show. With no history at all the
        # split falls to the cancellation — the story's default loss.
        {u2, _} = :rand.uniform_s(rest)

        if Decimal.lt?(Decimal.from_float(u2), cancellation_share(rates)) do
          @cancellation
        else
          @no_show
        end
      end

    %{
      appointment_id: visit.id,
      run: label,
      kind: outcome,
      occurred_at: instant(visit, outcome),
      amount: if(outcome == @completion, do: visit.amount),
      rate: rate,
      tier: tier,
      multiplier: multiplier
    }
  end

  # A completion happens at the visit's END (the slot's length, the same
  # instant a real write-up lands at); a loss lapses at the slot itself.
  defp instant(visit, @completion),
    do: DateTime.add(visit.scheduled_at, visit.duration_minutes * 60, :second)

  defp instant(visit, _lapsed), do: visit.scheduled_at

  # (visit_id, label) alone — never the multiplier, never the clock. The
  # digest spreads the pair across the three integers `:rand.seed_s`
  # wants, deterministically.
  defp seed_tuple(visit_id, label) do
    <<a::unsigned-integer-32, b::unsigned-integer-32, c::unsigned-integer-32, _::binary>> =
      :crypto.hash(:sha256, visit_id <> ":" <> label)

    {a, b, c}
  end

  defp clamp01(p) do
    p |> Decimal.max(Decimal.new(0)) |> Decimal.min(Decimal.new(1))
  end

  # cancelled / (cancelled + no_show) — the loss mix among the losses the
  # clinic actually observed. No observations: fall to the cancellation.
  defp cancellation_share(rates) do
    losses = rates.global.cancelled + rates.global.no_show

    if losses > 0 do
      Decimal.div(Decimal.new(rates.global.cancelled), Decimal.new(losses))
    else
      Decimal.new(1)
    end
  end

  defp weekday(%DateTime{} = dt), do: Date.day_of_week(DateTime.to_date(dt))

  # ── the record path (the real moments' exact discipline, on the twin) ──

  defp record!(planned) do
    version = active_version!(planned.kind)

    {:ok, canonical} =
      AshDiscreteBusinessEvents.Mappings.run(version, payload(planned))

    Ledger.SimulationEvent.record!(
      %{
        event_kind: canonical.event_kind,
        region: @region,
        residency_tag: @residency,
        subject_type: @subject_type,
        subject_external_id: planned.appointment_id,
        occurred_at: canonical.occurred_at,
        delivery_key: "scenario:#{run_of(planned)}:#{planned.appointment_id}:#{planned.kind}",
        simulation_run: run_of(planned),
        provenance: canonical.provenance,
        context: %{
          "scenario" => %{
            "multiplier" => Decimal.to_string(normalized(planned.multiplier)),
            "rate" => Decimal.to_string(planned.rate),
            "tier" => to_string(planned.tier)
          }
        },
        data: canonical.data
      },
      authorize?: false
    )

    :ok
  end

  # The label rides each plan entry — `plan/4` stamps it at draw time,
  # so the record path stays total and self-describing.
  defp run_of(planned), do: Map.fetch!(planned, :run)

  defp payload(planned) do
    base = %{
      "occurred_at" => planned.occurred_at,
      "appointment_id" => planned.appointment_id
    }

    case planned.kind do
      @completion -> Map.put(base, "amount", planned.amount)
      # A simulated loss states WHAT happened, never a fabricated why:
      # the reason map's absent-path leaves it out entirely.
      _lapsed -> base
    end
  end

  defp active_version!(kind) do
    AshDiscreteBusinessEvents.Mappings.active_version(MappingVersion, kind) ||
      raise ArgumentError,
            "no active mapping version for #{inspect(kind)} — run " <>
              "ClinicDemo.BusinessEvents.install!/0 before generating a scenario"
  end

  defp normalized(multiplier), do: multiplier |> Decimal.round(4) |> Decimal.normalize()

  defp default_label(multiplier, horizon_weeks),
    do: "scenario:x#{normalized(multiplier)}-h#{horizon_weeks}"

  # ── the reads around the draw ──────────────────────────────────────────

  defp run_events(label) do
    AshDiscreteBusinessEvents.simulation_runs(Ledger)
    |> Enum.find(&(&1.simulation_run == label))
    |> case do
      %{events: count} -> count
      _ -> 0
    end
  end

  defp durations(ids) do
    Appointment
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :duration_minutes])
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.id, &1.duration_minutes})
  end

  # The run's completions folded per Monday-anchored week — from the
  # run's OWN plan (the twin's ground truth), never from a projection
  # read that could straddle two runs sharing a subject. The horizon's
  # weeks always appear (zero rows included); a completion spilling
  # past the horizon's end opens its own trailing week.
  defp weeks(planned, horizon_weeks) do
    today = Date.utc_today()

    horizon_starts =
      for offset <- 0..(horizon_weeks - 1) do
        today |> Date.beginning_of_week() |> Date.add(7 * offset)
      end

    completions =
      planned
      |> Enum.filter(&(&1.kind == @completion))
      |> Enum.sort_by(& &1.occurred_at, &(DateTime.compare(&1, &2) != :gt))

    empty = %{week_start: nil, week_end: nil, recognized: Decimal.new(0), completions: 0}

    buckets =
      Map.new(horizon_starts, fn week_start ->
        {week_start, %{empty | week_start: week_start, week_end: Date.add(week_start, 6)}}
      end)

    buckets =
      Enum.reduce(completions, buckets, fn completion, buckets ->
        week_start =
          completion.occurred_at
          |> DateTime.to_date()
          |> Date.beginning_of_week()

        bucket =
          Map.get_lazy(buckets, week_start, fn ->
            %{empty | week_start: week_start, week_end: Date.add(week_start, 6)}
          end)

        bucket
        |> Map.update!(:recognized, &Decimal.add(&1, completion.amount))
        |> Map.update!(:completions, &(&1 + 1))
        |> then(&Map.put(buckets, week_start, &1))
      end)

    buckets
    |> Map.values()
    # Dates order only through `Date.compare/2` — term ordering on the
    # struct maps would sort November ahead of October.
    |> Enum.sort_by(& &1.week_start, &(Date.compare(&1, &2) != :gt))
    |> Enum.map(&Map.update!(&1, :recognized, fn total -> Decimal.round(total, 2) end))
  end
end
