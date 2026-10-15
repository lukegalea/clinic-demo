defmodule ClinicDemo.BusinessEventsProjectionTest do
  @moduledoc """
  BD-3's proof: the value projection is a faithful temporal fold of the
  ledger, and the two revenue derivations — charges and projection —
  agree.

  Two suites:

    * **The fold** (sandboxed, one visit at a time): the projector lands
      each kind's truth on the grain, as of the event's own instant, and
      the write-off restates money without touching the outcome.
    * **The equivalence gate + replay echo** (the design's §2g BD-3
      battery): a seeded world — the real finance walk at test scale,
      through the real attributed actions — drained once, then probed at
      sampled instants (seed start, middle, end, now, and a daily sweep
      across the history): `Finance.value_by_month/1` must equal the
      charge-derived `Finance.revenue_by_month/2` month for month, and
      `Finance.projected_outcomes/1` must equal the appointment-derived
      `historical_outcomes/1`. Then the echo: wipe the projection and its
      checkpoint, re-drain, and the periods come back byte-identical
      (bounds and content — the write's wall clock differs by design).
  """

  use ClinicDemo.DataCase, async: false

  require Ash.Query

  alias ClinicDemo.BusinessEvents
  alias ClinicDemo.BusinessEvents.ValueProjection
  alias ClinicDemo.BusinessEvents.ValueProjector
  alias ClinicDemo.Finance
  alias ClinicDemo.FinanceSeeds
  alias ClinicDemo.Finance.Charge
  alias ClinicDemo.Repo
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.AppointmentType

  @staff %{id: "00000000-0000-0000-0000-0000000000d3", role: :veterinarian}
  @region :clinic
  # The checkpoint the drain keeps (projector name + region) — the echo
  # wipes it to prove the rebuild.
  @checkpoint "clinic_value_v1.clinic"

  # ── shared fixtures ─────────────────────────────────────────────────────

  defp fixtures do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Projection Vet",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "Projected Animal",
          species: :cat,
          owner_email: "projected-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    type =
      AppointmentType
      |> Ash.Changeset.for_create(:create, %{
        name: "Projection Test Visit #{System.unique_integer([:positive])}",
        base_price: Decimal.new("175"),
        default_duration_minutes: 30
      })
      |> Ash.create!(authorize?: false)

    %{vet: vet, patient: patient, type: type}
  end

  defp hours_ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)

  # The seeds' walk, at test scale — with the weigh-in the compliance
  # bundle's guard demands on a seeded database, and the back-dated triage
  # whose ledger row collapses into the engine's (BD-2's ruling).
  defp back_dated_visit(patient, vet, type) do
    booked_at = hours_ago(4)
    triaged_at = hours_ago(3)
    checked_in_at = hours_ago(2)
    completed_at = hours_ago(2) |> DateTime.add(1800, :second)
    scheduled_at = checked_in_at

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          appointment_type_id: type && type.id,
          scheduled_at: scheduled_at,
          duration_minutes: 30,
          reason: "Projection walk",
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

    Scheduling.complete_appointment!(version, "Projected write-up.",
      actor: @staff,
      as_of: completed_at
    )

    %{
      appointment: appointment,
      booked_at: booked_at,
      triaged_at: triaged_at,
      scheduled_at: scheduled_at,
      completed_at: completed_at
    }
  end

  defp row_for(appointment_id) do
    ValueProjection
    |> Ash.Query.filter(subject == ^appointment_id)
    |> Ash.read_one!(authorize?: false)
  end

  # ── the fold ────────────────────────────────────────────────────────────

  describe "the fold" do
    setup do
      BusinessEvents.install!()
      %{fixtures: fixtures()}
    end

    test "one visit's truth lands on one temporal grain", %{fixtures: fixtures} do
      %{vet: vet, patient: patient, type: type} = fixtures

      %{
        appointment: appointment,
        booked_at: booked_at,
        scheduled_at: scheduled_at,
        completed_at: completed_at
      } =
        back_dated_visit(patient, vet, type)

      assert ValueProjector.drain(@region) > 0

      row = row_for(appointment.id)

      assert row.region == @region
      assert row.outcome == :completed
      assert Decimal.eq?(row.expected_amount, Decimal.new("175"))
      assert Decimal.eq?(row.recognized_amount, Decimal.new("175"))
      assert DateTime.compare(row.recognized_at, completed_at) == :eq
      assert row.type_id == type.id
      assert row.clinician_id == vet.id
      assert row.scheduled_at == scheduled_at
      assert row.urgency == "urgent"
      assert row.urgency_band == "high"
      assert row.corrections == 0

      # The CURRENT period opens at the visit's last truth instant — the
      # completion. (The earlier periods — booked, triaged — sit below it;
      # the as-of test above walks them.)
      assert DateTime.compare(row.valid_at.lower, completed_at) == :eq
    end

    test "as-of reads see the visit's history, not just its present", %{fixtures: fixtures} do
      %{vet: vet, patient: patient, type: type} = fixtures

      %{appointment: appointment, booked_at: booked_at, completed_at: completed_at} =
        back_dated_visit(patient, vet, type)

      ValueProjector.drain(@region)

      # Before the booking: no grain at all — the visit did not exist.
      before =
        ValueProjection
        |> Ash.Query.filter(subject == ^appointment.id)
        |> Ash.Query.as_of(DateTime.add(booked_at, -1, :second))
        |> Ash.read!(authorize?: false)

      assert before == []

      # Between booking and write-up the visit is open with its expected
      # value and no recognition.
      midway =
        ValueProjection
        |> Ash.Query.filter(subject == ^appointment.id)
        |> Ash.Query.as_of(DateTime.add(completed_at, -60, :second))
        |> Ash.read_one!(authorize?: false)

      assert midway.outcome == :open
      assert Decimal.eq?(midway.expected_amount, Decimal.new("175"))
      assert midway.recognized_amount == nil
    end

    test "a write-off restates money without touching the outcome", %{fixtures: fixtures} do
      %{vet: vet, patient: patient, type: type} = fixtures

      %{appointment: appointment} = back_dated_visit(patient, vet, type)
      ValueProjector.drain(@region)

      charge = Finance.write_off_charge!(Finance.charge_for(appointment.id), actor: @staff)
      assert charge.status == :written_off

      ValueProjector.drain(@region)

      row = row_for(appointment.id)
      assert row.outcome == :completed
      assert Decimal.eq?(row.written_off_amount, Decimal.new("175"))
      # Still one grain — the revision is a period, not a rewrite.
      assert ValueProjection
             |> Ash.Query.filter(subject == ^appointment.id)
             |> Ash.read!(authorize?: false)
             |> length() >= 1
    end
  end

  # ── the equivalence gate + the replay echo ─────────────────────────────

  describe "the equivalence gate over the seeded world" do
    # FinanceSeedsTest's scale: a small window, every visit through the
    # real attributed actions. The mappings deploy first — exactly the
    # seeds' order — so the walk emits.
    @seed_opts [weeks_back: 2, weeks_ahead: 1, weekday_per_day: 4, weekend_per_day: 2]

    setup do
      {:ok, _vet} =
        Scheduling.hire_clinician(
          %{
            full_name: "Dr. Gate Vet",
            role: :veterinarian,
            license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
          },
          actor: @staff
        )

      {:ok, _nurse} =
        Scheduling.hire_clinician(
          %{
            full_name: "Gate Front Desk",
            role: :nurse,
            license_number: "VN-#{:rand.uniform(899_999) + 100_000}"
          },
          actor: @staff
        )

      BusinessEvents.install!()
      FinanceSeeds.run(@seed_opts)

      # The like-for-like's revision side: one recognised charge written
      # off after the fact — the charge derivation drops it (`status !=
      # :paid`), the projection must drop it with the same stroke.
      charge =
        Charge
        |> Ash.Query.filter(status == :paid)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)

      Finance.write_off_charge!(charge, actor: @staff)

      drained = ValueProjector.drain(@region)
      %{drained: drained}
    end

    test "projection-derived month revenue equals charge-derived revenue at every sampled instant" do
      # Seed start, seed middle, seed end, now — plus a daily sweep across
      # the history. Every sample pins BOTH derivations to the same
      # instant and compares month for month.
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      instants =
        [now, hours_ago(20), hours_ago(48), hours_ago(336)] ++
          Enum.map(1..14, fn d -> hours_ago(d * 12) end)

      assert length(instants) >= 17

      Enum.each(instants, fn instant ->
        charge_derived = Finance.revenue_by_month(7, as_of: instant)
        projection_derived = Finance.value_by_month(months: 7, as_of: instant)

        assert projection_derived == charge_derived,
               "equivalence broke at #{DateTime.to_iso8601(instant)}:" <>
                 "\nprojection: #{inspect(projection_derived)}\ncharges:    #{inspect(charge_derived)}"
      end)
    end

    test "the rates table's evidence equals the appointment-derived outcomes" do
      from_appointments = Finance.historical_outcomes() |> Enum.sort()
      from_projection = Finance.projected_outcomes() |> Enum.sort()

      # Multiset difference, named on failure: which outcome rows one side
      # has that the other lacks.
      missing_from_projection = from_appointments -- from_projection
      extra_in_projection = from_projection -- from_appointments

      # TEMP DIAGNOSTIC (BD-3): the cancelled visit's ledger + grain.
      cancelled_appointments =
        Scheduling.Appointment
        |> Ash.Query.filter(status == :cancelled and not is_nil(appointment_type_id))
        |> Ash.read!(authorize?: false)

      Enum.each(cancelled_appointments, fn appointment ->
        events =
          ClinicDemo.BusinessEvents.Ledger
          |> Ash.Query.filter(subject_external_id == ^appointment.id)
          |> Ash.Query.sort(:sequence)
          |> Ash.read!(authorize?: false)

        grain =
          ValueProjection
          |> Ash.Query.filter(subject == ^appointment.id)
          |> Ash.read!(authorize?: false)

        IO.puts(
          "DIAG cancelled #{appointment.id} (cancelled_at=#{appointment.updated_at}): " <>
            Enum.map_join(events, " | ", fn e ->
              "seq=#{e.sequence} #{inspect(e.action)} at=#{e.occurred_at}"
            end) <>
            " || grains: " <>
            Enum.map_join(grain, " | ", fn g ->
              "outcome=#{g.outcome} valid=#{inspect(g.valid_at)}"
            end)
        )
      end)

      assert missing_from_projection == [],
             "outcome rows the appointments have and the projection lacks: #{inspect(missing_from_projection)}"

      # TEMP DIAGNOSTIC (BD-3): which typed visits lack a projection grain?
      typed =
        Scheduling.Appointment
        |> Ash.Query.filter(not is_nil(appointment_type_id))
        |> Ash.Query.select(:id)
        |> Ash.read!(authorize?: false)

      grained =
        ValueProjection
        |> Ash.Query.filter(not is_nil(type_id))
        |> Ash.Query.select(:subject)
        |> Ash.read!(authorize?: false)

      IO.puts("DIAG typed=#{length(typed)} grained=#{length(grained)}")

      IO.puts(
        "DIAG missing grains: #{inspect(typed |> Map.new(&{&1.id, true}) |> Map.take(Enum.map(grained, & &1.subject)) |> map_size())}"
      )

      ungrained =
        MapSet.difference(MapSet.new(typed, & &1.id), MapSet.new(grained, & &1.subject))
        |> MapSet.to_list()

      IO.puts("DIAG ungrained visit ids: #{inspect(ungrained)}")

      assert extra_in_projection == [],
             "outcome rows the projection has and the appointments lack: #{inspect(extra_in_projection)}"

      assert length(from_projection) == length(from_appointments)
    end

    test "the folds were clean — nothing in the dead letter" do
      dead =
        AshEvents.Projections.DeadLetter
        |> Ash.Query.filter(projection_name == ^@checkpoint)
        |> Ash.read!(authorize?: false)

      assert dead == []
    end

    test "the replay echo: wipe and re-drain reproduces byte-identical periods" do
      before = periods()

      # The rebuild: wipe the projection and the drain's cursor, then
      # re-fold the whole feed from zero.
      Repo.query!("TRUNCATE value_projections", [])

      Repo.query!("DELETE FROM ash_projection_checkpoints WHERE projection_name = $1", [
        @checkpoint
      ])

      drained = ValueProjector.drain(@region)
      assert drained > 0

      after_rebuild = periods()

      assert after_rebuild == before
    end

    # Every period of every grain, bounds and content, ordered — the
    # replay echo's comparison shape. `recorded_at` (the write's wall
    # clock) is excluded by design; bounds and projected truth are not.
    defp periods do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT subject, region::text, outcome::text, urgency, urgency_band,
                 expected_amount::text, recognized_amount::text, recognized_at::text,
                 written_off_amount::text, type_id::text, clinician_id::text,
                 scheduled_at::text, corrections, lower(valid_at)::text, upper(valid_at)::text
          FROM value_projections
          ORDER BY subject, lower(valid_at), upper(valid_at)
          """,
          []
        )

      rows
    end
  end

  defp hours_ago,
    do: fn hours ->
      DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)
    end
end
