defmodule ClinicDemo.BusinessEventsScenariosTest do
  @moduledoc """
  BD-5's isolation + determinism set (design §2g, risk #2), modeled on the
  package's `simulation_isolation_test.exs` — restated host-side, where the
  package's isolation deliberately stops: the feed and the checkpoint are
  the package's; **the projection target is ours**.

  The pins:

    * **Real rows untouched at future instants** — after a scenario draws
      completions for future visits, the real ledger still says only what
      really happened (`visit_booked`, nothing future-dated), and the sim
      projection is empty at the present: every simulated period lives in
      the future, in its own table. (When BD-3's real `ValueProjection`
      lands, its half of this pin — zero future-dated periods, zero
      run-labeled rows — is its own test; the ledger half lives here.)
    * **Sim rows never leak into real reads** — the twin is another table;
      the real subject feed carries no drawn outcome, and the run listing
      is the twin's alone.
    * **Run separation** — two knobs are two runs: two `sim:`-namespaced
      cursors, no bare checkpoint row, each drain consuming only its own
      run's rows (even after a cursor wipe, the sim drain re-reads the
      twin, never the real feed).
    * **Regeneration is a no-op** — same label, same knobs: delivery keys
      collapse, the twin and the sim projection gain nothing, the cursor
      is already at its tail.
    * **Determinism** — the pure draw: same `(visit, label, multiplier)`
      → the identical multiset; the seed is `(visit_id, label)` alone, so
      a higher multiplier only ever moves a visit toward completion; the
      saturating edge folds every price in, exactly.
  """

  use ClinicDemo.DataCase, async: false

  require Ash.Query

  alias ClinicDemo.BusinessEvents
  alias ClinicDemo.BusinessEvents.Ledger
  alias ClinicDemo.BusinessEvents.Scenarios
  alias ClinicDemo.BusinessEvents.SimValueProjection
  alias ClinicDemo.BusinessEvents.SimValueProjector
  alias ClinicDemo.Repo
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.AppointmentType

  @region :clinic
  @projector "sim_value_projection_v1"

  setup do
    versions = BusinessEvents.install!()
    %{versions: versions}
  end

  # ── fixtures, in the wiring test's shape ────────────────────────────────

  defp fixtures do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Scenario Vet",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: staff()
      )

    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "Scenario Animal",
          species: :dog,
          owner_email: "scenario-#{System.unique_integer([:positive])}@example.com"
        },
        actor: staff()
      )

    %{vet: vet, patient: patient}
  end

  defp staff, do: %{id: "00000000-0000-0000-0000-0000000000d3", role: :veterinarian}

  defp catalogue_type(price) do
    AppointmentType
    |> Ash.Changeset.for_create(:create, %{
      name: "Scenario Visit #{System.unique_integer([:positive])}",
      base_price: price,
      default_duration_minutes: 30
    })
    |> Ash.create!(authorize?: false)
  end

  # A visit still ahead of us: the scenario's raw material. Booked now for
  # three days out — the real ledger gains only the booking.
  defp future_visit(patient, vet, type, in_days) do
    scheduled_at =
      DateTime.utc_now()
      |> DateTime.add(in_days * 86_400, :second)
      |> DateTime.truncate(:second)

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          appointment_type_id: type.id,
          scheduled_at: scheduled_at,
          duration_minutes: 30,
          reason: "Scenario bait",
          severity: 2
        },
        actor: staff()
      )

    appointment
  end

  # A terminal history visit at test scale: booked, and walked to its
  # outcome, all in the present tense. The seeds walk back-dated and then
  # re-assert at the present — the appointment is temporal, and only the
  # CURRENT version teaches the rate table — so a fixture that back-dates
  # without re-asserting would leave its "history" sitting in :open.
  # Each walk gets its OWN patient: the admitted acuity FACT is keyed on
  # the patient, so five walks sharing one would fight over one fact
  # period; five patients are five independent timelines.
  defp history_visit(vet, type, outcome) do
    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "History Animal #{System.unique_integer([:positive])}",
          species: :dog,
          owner_email: "history-#{System.unique_integer([:positive])}@example.com"
        },
        actor: staff()
      )

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          appointment_type_id: type && type.id,
          # The booking validates a future slot; five minutes out is
          # future enough, and the walk starts immediately — the visit's
          # STATUS is what teaches the rate table.
          scheduled_at:
            DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.truncate(:second),
          duration_minutes: 30,
          reason: "Scenario history",
          severity: 2
        },
        actor: staff()
      )

    case outcome do
      :completed ->
        Scheduling.record_weight(patient, Decimal.new("5.0"), actor: staff())
        version = Scheduling.get_appointment!(appointment.id)
        version = Scheduling.check_in_appointment!(version, actor: staff())
        Scheduling.complete_appointment!(version, "History walk.", actor: staff())

      :cancelled ->
        version = Scheduling.get_appointment!(appointment.id)
        Scheduling.cancel_appointment!(version, "History cancel.", actor: staff())

      # A no-show lapses from the slot: the machine allows it only from
      # :scheduled — the visit never started.
      :no_show ->
        version = Scheduling.get_appointment!(appointment.id)
        Scheduling.mark_appointment_no_show!(version, actor: staff())
    end
  end

  # 3 completed + 1 cancelled + 1 no_show: a rate of 0.6, a loss mix of
  # 1:1 — enough observations for the global cell (min 3) and a split the
  # draw can actually exercise.
  defp teach_rates(_patient, vet, type) do
    walks = [:completed, :completed, :completed, :cancelled, :no_show]

    Enum.each(walks, fn outcome ->
      history_visit(vet, type, outcome)
    end)
  end

  defp twin_rows(label) do
    Ledger.SimulationEvent
    |> Ash.Query.filter(simulation_run == ^label)
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(& &1.sequence)
  end

  defp checkpoints do
    Repo.all(
      from(cp in "ash_projection_checkpoints",
        select: %{name: cp.projection_name, seen: cp.last_seen_event_id}
      )
    )
  end

  defp sim_periods_at(instant) do
    SimValueProjection
    |> Ash.Query.as_of(instant)
    |> Ash.read!(authorize?: false)
  end

  defp real_feed do
    Ledger.by_region!(@region)
  end

  # ── determinism: the pure draw ──────────────────────────────────────────

  describe "the pure draw" do
    setup %{versions: _} do
      :ok
    end

    defp visit_row(id, price, type_id, clinician_id, at),
      do: %{
        id: id,
        appointment_type_id: type_id,
        clinician_id: clinician_id,
        scheduled_at: at,
        amount: price,
        duration_minutes: 30
      }

    defp rates do
      %{
        cell: %{},
        type_weekday: %{},
        type: %{},
        weekday: %{},
        global: %{completed: 6, cancelled: 2, no_show: 2}
      }
    end

    defp visit_ids,
      do:
        Enum.map(1..12, &"00000000-0000-0000-0000-#{String.pad_leading(to_string(&1), 12, "0")}")

    defp next_week do
      DateTime.utc_now() |> DateTime.add(7 * 86_400, :second) |> DateTime.truncate(:second)
    end

    test "the same (visits, label, multiplier) draw the identical multiset" do
      visits = Enum.map(visit_ids(), &visit_row(&1, Decimal.new("100"), nil, nil, next_week()))
      rates = rates()

      first = Scenarios.plan(visits, "determinism-pin", rates, Decimal.new("0.5"))
      second = Scenarios.plan(visits, "determinism-pin", rates, Decimal.new("0.5"))

      assert first == second
      assert length(first) == 12
    end

    test "a higher multiplier only ever moves a visit toward completion" do
      visits = Enum.map(visit_ids(), &visit_row(&1, Decimal.new("100"), nil, nil, next_week()))
      rates = rates()

      low = Scenarios.plan(visits, "monotone-pin", rates, Decimal.new("0.2"))
      high = Scenarios.plan(visits, "monotone-pin", rates, Decimal.new("0.9"))

      completed_at = fn plan ->
        plan |> Enum.filter(&(&1.kind == :visit_completed)) |> MapSet.new(& &1.appointment_id)
      end

      # Same seed, higher bar cleared more often: every visit the low knob
      # completed, the high knob completed too — and the high knob never
      # loses a visit the low one completed.
      assert MapSet.subset?(completed_at.(low), completed_at.(high))
    end

    test "the saturating edge completes every visit at its full price" do
      prices =
        Enum.map(visit_ids(), fn id ->
          visit_row(id, Decimal.new("100"), nil, nil, next_week())
        end)

      plan = Scenarios.plan(prices, "saturation-pin", rates(), Decimal.new("99"))

      assert Enum.all?(plan, &(&1.kind == :visit_completed))
      assert Enum.all?(plan, &Decimal.eq?(&1.amount, Decimal.new("100")))

      # A completion happens at the visit's END: slot + its own duration.
      Enum.each(plan, fn entry ->
        slot = Enum.find(prices, &(&1.id == entry.appointment_id)).scheduled_at
        assert DateTime.compare(entry.occurred_at, DateTime.add(slot, 1800, :second)) == :eq
      end)
    end

    test "the zero edge completes nothing, and losses lapse at the slot itself" do
      visits = Enum.map(visit_ids(), &visit_row(&1, Decimal.new("100"), nil, nil, next_week()))

      plan = Scenarios.plan(visits, "zero-pin", rates(), Decimal.new("0"))

      assert Enum.all?(plan, &(&1.kind in [:visit_cancelled, :visit_no_show]))
      assert Enum.any?(plan, &(&1.kind == :visit_cancelled))
      assert Enum.any?(plan, &(&1.kind == :visit_no_show))

      Enum.each(plan, fn entry ->
        slot = Enum.find(visits, &(&1.id == entry.appointment_id)).scheduled_at
        assert DateTime.compare(entry.occurred_at, slot) == :eq
        assert entry.amount == nil
      end)
    end
  end

  # ── isolation: the three-AC model, host-side ────────────────────────────

  describe "generate! end to end" do
    test "two knobs are two runs: listed, separate, and the real ledger never notices", %{
      versions: _versions
    } do
      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type(Decimal.new("175"))
      teach_rates(patient, vet, type)

      visits = Enum.map([3, 5, 10, 12], &future_visit(patient, vet, type, &1))
      real_before = length(real_feed())

      low = Scenarios.generate!(multiplier: Decimal.new("0.0"))
      high = Scenarios.generate!(multiplier: Decimal.new("99"))

      assert low.generated == 4
      assert high.generated == 4
      assert low.run == "scenario:x0-h4"
      assert high.run == "scenario:x99-h4"

      # Both runs listed, four twin rows each — the AC-3 read.
      runs = Scenarios.runs()
      run_labels = Enum.map(runs, & &1.simulation_run)
      assert low.run in run_labels and high.run in run_labels
      assert Enum.find(runs, &(&1.simulation_run == low.run)).events == 4
      assert Enum.find(runs, &(&1.simulation_run == high.run)).events == 4

      # The zero knob drew only losses; the saturating knob only wins.
      assert Enum.all?(twin_rows(low.run), &(&1.action in [:visit_cancelled, :visit_no_show]))
      assert Enum.all?(twin_rows(high.run), &(&1.action == :visit_completed))

      # Every twin row is unmistakable by shape and delivery key.
      for label <- [low.run, high.run] do
        for row <- twin_rows(label) do
          assert row.simulated == true
          assert row.simulation_run == label
          assert String.starts_with?(row.delivery_key, "scenario:#{label}:")
        end
      end

      # Real rows untouched: same count as before, nothing future-dated,
      # and a drawn completion NEVER joined the real subject's feed — the
      # real ledger still says only "booked".
      feed = real_feed()
      assert length(feed) == real_before
      assert Enum.all?(feed, &(DateTime.compare(&1.occurred_at, DateTime.utc_now()) != :gt))

      for visit <- visits do
        # The real subject's feed says only what really happened — the
        # booking and its engine triage and nothing more: NO drawn
        # outcome of any kind ever joined the real ledger.
        actions = Enum.map(Ledger.by_subject!(@region, visit.id), & &1.action)

        assert :visit_completed not in actions
        assert :visit_cancelled not in actions
        assert :visit_no_show not in actions
      end

      # Run separation at the cursor: exactly two sim-namespaced rows, no
      # bare checkpoint ever created.
      cps = checkpoints()
      assert length(cps) == 2

      assert Enum.sort(Enum.map(cps, & &1.name)) ==
               Enum.sort([
                 "sim:#{@projector}.#{@region}:#{low.run}",
                 "sim:#{@projector}.#{@region}:#{high.run}"
               ])
    end

    test "the sim drain reads the twin alone, even after a cursor wipe", %{versions: _versions} do
      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type(Decimal.new("90"))
      teach_rates(patient, vet, type)

      Enum.each([2, 4, 6], &future_visit(patient, vet, type, &1))
      real_size = length(real_feed())

      run = Scenarios.generate!(multiplier: Decimal.new("1")).run

      assert Scenarios.runs() |> Enum.find(&(&1.simulation_run == run)) |> Map.fetch!(:events) ==
               3

      # Wipe the cursors and re-drain: the sim drain consumes the run's
      # three twin rows again — three, not three-plus-the-real-feed. The
      # real log is not an input this drain can even reach.
      Repo.delete_all("ash_projection_checkpoints")

      assert SimValueProjector.drain_simulation(run, @region) == 3
      assert SimValueProjector.drain_simulation(run, @region) == 0
      assert real_size == length(real_feed())
    end

    test "regeneration is a no-op", %{versions: _versions} do
      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type(Decimal.new("60"))
      teach_rates(patient, vet, type)

      Enum.each([1, 2, 3, 8], &future_visit(patient, vet, type, &1))

      first = Scenarios.generate!(multiplier: Decimal.new("0.5"))

      periods_before = Repo.aggregate(SimValueProjection, :count, :id)
      cps_before = checkpoints()

      second = Scenarios.generate!(multiplier: Decimal.new("0.5"))

      assert second.run == first.run
      assert second.generated == first.generated
      assert second.appended == 0
      assert second.events == first.events
      assert Repo.aggregate(SimValueProjection, :count, :id) == periods_before
      assert checkpoints() == cps_before
    end

    test "the sim lives in the future: empty at now, folded at the run's instants", %{
      versions: _versions
    } do
      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type(Decimal.new("120"))
      teach_rates(patient, vet, type)

      Enum.each([4, 9], &future_visit(patient, vet, type, &1))

      result = Scenarios.generate!(multiplier: Decimal.new("99"))

      # Every simulated period is future-dated: the present reads empty.
      assert sim_periods_at(DateTime.utc_now()) == []

      future = DateTime.utc_now() |> DateTime.add(20 * 86_400, :second)
      periods = sim_periods_at(future)
      assert length(periods) == 2

      # The fold's grain: one row per visit, and the saturating knob's
      # completions recognized their full price at the drawn instants.
      assert Enum.all?(periods, &(&1.outcome == :completed and &1.region == @region))

      assert Enum.map(periods, & &1.recognized_amount)
             |> Enum.all?(&Decimal.eq?(&1, Decimal.new("120")))

      # The generator's weekly summary folds the run's own completions.
      total =
        Enum.reduce(result.weeks, Decimal.new(0), fn week, acc ->
          Decimal.add(acc, week.recognized)
        end)

      assert Decimal.eq?(total, Decimal.new("240.00"))
      assert Enum.sum(Enum.map(result.weeks, & &1.completions)) == 2
    end

    test "scenario events ride the active mapping's provenance and structural context only", %{
      versions: versions
    } do
      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type(Decimal.new("175"))
      teach_rates(patient, vet, type)

      future_visit(patient, vet, type, 5)

      # A saturating knob: every visit completes, so the twin row under
      # test is unambiguously a completion.
      result = Scenarios.generate!(multiplier: Decimal.new("99"))
      [row] = twin_rows(result.run)

      active = Enum.find(versions, &(&1.mapping_name == "visit_completed"))
      assert row.provenance["mapping_name"] == "visit_completed"
      assert row.provenance["mapping_version_hash"] == active.version_hash

      # The canonical completion data: the amount and nothing personal.
      assert row.data == %{"amount" => "175", "source_system" => "clinic_core"}

      # Structural facts only — the knob's setting, never an actor.
      %{context: %{"scenario" => scenario}} = row
      assert Map.keys(scenario) |> Enum.sort() == ["multiplier", "rate", "tier"]
      assert scenario["multiplier"] == "99"
    end
  end
end
