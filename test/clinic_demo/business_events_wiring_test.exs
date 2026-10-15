defmodule ClinicDemo.BusinessEventsWiringTest do
  @moduledoc """
  BD-2's wiring set: the six lifecycle moments become ledger events,
  through the real code interfaces, with the exact kinds, payloads,
  provenance and idempotency the design pins.

  The contract under test:

    * walking `:book` → `:record_triage` → `:complete` appends the
      expected kinds, `occurred_at` = the write's `as_of`, `observed_at`
      after it (the three-clocks split, on back-dated writes),
    * the seeds' double-walk (back-dated write plus the present-tense
      re-assert) appends ONE `visit.completed` — delivery collapse,
    * a no-type completion writes `visit.completed` with NO amount key
      (the mapping's absent-path semantics),
    * patient names and clinical notes never appear in `data` (PII pin),
    * the write-off is a new event, never a rewrite of the completion,
    * with no active mapping version (before `install!/0`), the hooks
      step aside: the pre-ledger world, not a broken one.

  Event reads ride the generated interfaces (`by_subject!`), exactly as
  BD-3's projector and any surface will.
  """

  use ClinicDemo.DataCase, async: true

  require Ash.Query

  alias ClinicDemo.BusinessEvents
  alias ClinicDemo.BusinessEvents.Ledger
  alias ClinicDemo.Finance
  alias ClinicDemo.Finance.Charge
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.AppointmentType

  @staff %{id: "00000000-0000-0000-0000-0000000000d2", role: :veterinarian}
  @region :clinic

  setup context do
    # The undeployed case deliberately skips deployment: that is its
    # subject under test.
    versions = if context[:undeployed], do: nil, else: BusinessEvents.install!()
    %{versions: versions}
  end

  # ── fixtures, in the finance_test shape ─────────────────────────────────

  defp fixtures do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Wiring Vet",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "Wired Animal",
          species: :cat,
          owner_email: "wiring-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    %{vet: vet, patient: patient}
  end

  defp catalogue_type do
    AppointmentType
    |> Ash.Changeset.for_create(:create, %{
      name: "Wiring Test Visit #{System.unique_integer([:positive])}",
      base_price: Decimal.new("175"),
      default_duration_minutes: 30
    })
    |> Ash.create!(authorize?: false)
  end

  defp hours_ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)

  defp tomorrow_at_hour(hour) do
    Date.utc_today()
    |> Date.add(1)
    |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
  end

  # The seeds' walk, at test scale: book three hours back, triage two
  # hours back, check in one hour back, write up half an hour back.
  defp back_dated_visit(patient, vet, type) do
    booked_at = hours_ago(3)
    triaged_at = hours_ago(2)
    checked_in_at = hours_ago(1)
    completed_at = hours_ago(1) |> DateTime.add(1800, :second)
    scheduled_at = checked_in_at

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          appointment_type_id: type && type.id,
          scheduled_at: scheduled_at,
          duration_minutes: 30,
          reason: "Wiring walk",
          severity: 2
        },
        actor: @staff,
        as_of: booked_at
      )

    # Booking starts the visit process, whose synchronous triage write
    # happens at seed-run wall clock (the engine is not temporal) — the
    # history's own triage is the seeds' back-dated re-assert. The
    # engine's answer is the one the ledger keeps (delivery collapse).
    version = Scheduling.get_appointment!(appointment.id, as_of: triaged_at)
    Scheduling.record_appointment_triage!(version, :urgent, actor: @staff, as_of: triaged_at)

    # The weigh-in before check-in: the seeds' own discipline. With the
    # appointment bundle in force (a seeded local database) the check-in
    # guard demands it; without the bundle it is simply good practice.
    Scheduling.record_weight(patient, Decimal.new("5.0"), actor: @staff)

    version = Scheduling.get_appointment!(appointment.id, as_of: checked_in_at)
    Scheduling.check_in_appointment!(version, actor: @staff, as_of: checked_in_at)

    version = Scheduling.get_appointment!(appointment.id, as_of: completed_at)

    {:ok, _} =
      Scheduling.complete_appointment(version, "Wired up for the wiring test.",
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

  defp events_for(appointment_id), do: Ledger.by_subject!(@region, appointment_id)

  defp kinds_for(appointment_id) do
    appointment_id |> events_for() |> Enum.map(& &1.action) |> Enum.sort()
  end

  # ── the walk produces the ledger ────────────────────────────────────────

  describe "the seeded walk emits through the hooks" do
    test "book → triage → complete appends exactly the expected kinds", %{versions: versions} do
      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type()

      %{appointment: appointment, booked_at: booked_at, scheduled_at: scheduled_at} =
        back_dated_visit(patient, vet, type)

      # booked + triaged (the booking's own decision) + completed. No
      # check-in or discharge events — those moments change no value.
      assert kinds_for(appointment.id) == [:visit_booked, :visit_completed, :visit_triaged]

      [booked] = Enum.filter(events_for(appointment.id), &(&1.action == :visit_booked))

      assert booked.subject_type == "clinic.visit"
      assert booked.subject_external_id == appointment.id
      assert booked.region == @region
      assert booked.residency_tag == "ca"

      # The three clocks on a back-dated write: truth time is the write's
      # as_of, knowledge time is the wall clock after it, sequence is
      # commit order.
      assert DateTime.compare(booked.occurred_at, booked_at) == :eq
      assert DateTime.compare(booked.observed_at, booked.occurred_at) == :gt

      # Canonical data, post-mapping: expected value, the slot, severity,
      # and the two forecast dimensions BD-3's projection folds (BD-3
      # extended the mapping — a changed declaration mints a new version
      # row). The decimal rides its JSON string form, like every :map
      # attribute round-trip. The slot's canonical type is :utc_datetime
      # (second precision, no usec).
      assert booked.data == %{
               "expected_amount" => "175",
               "scheduled_at" => DateTime.to_iso8601(scheduled_at),
               "severity" => 2,
               "clinician_id" => vet.id,
               "type_id" => type.id,
               "source_system" => "clinic_core"
             }

      # Provenance resolves to the active mapping version.
      booked_version =
        Enum.find(versions, &(&1.mapping_name == "visit_booked"))

      assert booked.provenance["mapping_name"] == "visit_booked"
      assert booked.provenance["mapping_version_hash"] == booked_version.version_hash
    end

    test "the triage event carries the decision at the story instant", %{
      versions: _versions
    } do
      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type()

      %{appointment: appointment, triaged_at: triaged_at} = back_dated_visit(patient, vet, type)

      # TWO triage writes happened: the engine's synchronous answer inside
      # the booking (at the booking's wall clock) and the walk's back-dated
      # re-assert. Per the BD-3 RULING (2026-10-15, "the engine's triage
      # event is live-only"), the engine's write for a BACK-DATED booking
      # emits no ledger row — the walk's own re-assert lands at the story
      # instant under the delivery key. One triage per visit, at the
      # instant the story says it happened.
      assert [triaged] = Enum.filter(events_for(appointment.id), &(&1.action == :visit_triaged))

      assert triaged.delivery_key == "clinic.visit_triaged:#{appointment.id}"
      assert DateTime.compare(triaged.occurred_at, triaged_at) == :eq
      assert triaged.data["urgency"] == "urgent"
      assert triaged.data["urgency_band"] == "high"
      assert triaged.data["severity"] == 2
      assert triaged.data["source_system"] == "clinic_core"
    end

    test "a live booking's engine triage emits, and a re-triage collapses into it", %{
      versions: _versions
    } do
      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type()

      # A live booking: the engine's synchronous triage is the clinic's
      # real answer, recorded at the wall clock.
      {:ok, appointment} =
        Scheduling.book_appointment(
          %{
            patient_id: patient.id,
            clinician_id: vet.id,
            appointment_type_id: type.id,
            scheduled_at: tomorrow_at_hour(12),
            duration_minutes: 30,
            reason: "Wiring live triage",
            severity: 2
          },
          actor: @staff
        )

      engine_triage =
        Enum.find(events_for(appointment.id), &(&1.action == :visit_triaged))

      assert engine_triage
      standing = Scheduling.get_appointment!(appointment.id)
      assert engine_triage.data["urgency"] == to_string(standing.triage_urgency)

      # A later re-triage folds into the engine's answer (the live-bookings
      # collapse — the amended BD-2 ruling).
      Scheduling.record_appointment_triage!(appointment, :routine, actor: @staff)

      assert Enum.count(events_for(appointment.id), &(&1.action == :visit_triaged)) == 1
    end

    test "the completion event reads the charge it recognized", %{versions: _versions} do
      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type()

      %{appointment: appointment} = back_dated_visit(patient, vet, type)

      [completed] =
        Enum.filter(events_for(appointment.id), &(&1.action == :visit_completed))

      assert completed.data["amount"] == "175"
      assert completed.data["source_system"] == "clinic_core"
      refute Map.has_key?(completed.data, "recognized_at")

      charge = Finance.charge_for(appointment.id)
      assert Decimal.eq?(Decimal.new(completed.data["amount"]), charge.amount)
    end

    test "a no-type completion writes the event with no amount key", %{versions: _versions} do
      %{vet: vet, patient: patient} = fixtures()

      %{appointment: appointment} = back_dated_visit(patient, vet, nil)

      assert Finance.charge_for(appointment.id) == nil

      [completed] =
        Enum.filter(events_for(appointment.id), &(&1.action == :visit_completed))

      # Absent-path semantics: no amount, no silent nil — the mapping
      # simply has nothing to write.
      refute Map.has_key?(completed.data, "amount")
      assert completed.data["source_system"] == "clinic_core"
    end
  end

  # ── the double-walk collapses ───────────────────────────────────────────

  describe "delivery keys absorb the seeds' double-walk" do
    test "a re-asserted complete appends ONE visit.completed, and moves no charge", %{
      versions: _versions
    } do
      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type()

      %{appointment: appointment} = back_dated_visit(patient, vet, type)

      # The seeds' re-assert: walk :complete again at the present, exactly
      # as a resumed back-dated walk does.
      open = Scheduling.get_appointment!(appointment.id)

      if open.status == :scheduled do
        open = Scheduling.check_in_appointment!(open, actor: @staff)
        Scheduling.complete_appointment!(open, "Re-asserted write-up.", actor: @staff)
      end

      completions =
        Enum.filter(events_for(appointment.id), &(&1.action == :visit_completed))

      assert length(completions) == 1
      # The charge knows the same ruling.
      assert Charge
             |> Ash.Query.filter(appointment_id == ^appointment.id)
             |> Ash.read!(authorize?: false)
             |> length() == 1
    end
  end

  # ── the story's losses and revisions ────────────────────────────────────

  describe "the outcome and write-off moments" do
    test "a cancellation carries the reason the desk gave", %{versions: _versions} do
      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type()

      booked_at = hours_ago(3)

      {:ok, appointment} =
        Scheduling.book_appointment(
          %{
            patient_id: patient.id,
            clinician_id: vet.id,
            appointment_type_id: type.id,
            scheduled_at: tomorrow_at_hour(9),
            duration_minutes: 30,
            reason: "Wiring cancel walk",
            severity: 2
          },
          actor: @staff,
          as_of: booked_at
        )

      {:ok, _} =
        Scheduling.cancel_appointment(appointment, "Owner is away; will rebook", actor: @staff)

      [cancelled] = Enum.filter(events_for(appointment.id), &(&1.action == :visit_cancelled))

      assert cancelled.data["reason"] == "Owner is away; will rebook"
      assert cancelled.data["source_system"] == "clinic_core"
      # The expected value rode the booking; the loss is its own event.
      assert :visit_booked in kinds_for(appointment.id)
    end

    test "a no-show carries nothing but the fact", %{versions: _versions} do
      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type()

      {:ok, appointment} =
        Scheduling.book_appointment(
          %{
            patient_id: patient.id,
            clinician_id: vet.id,
            appointment_type_id: type.id,
            scheduled_at: tomorrow_at_hour(10),
            duration_minutes: 30,
            reason: "Wiring no-show walk",
            severity: 1
          },
          actor: @staff
        )

      {:ok, _} = Scheduling.mark_appointment_no_show(appointment, actor: @staff)

      [no_show] = Enum.filter(events_for(appointment.id), &(&1.action == :visit_no_show))

      assert no_show.data == %{"source_system" => "clinic_core"}
    end

    test "a write-off is a new event, never a rewrite of the completion", %{
      versions: _versions
    } do
      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type()

      %{appointment: appointment} = back_dated_visit(patient, vet, type)

      charge = Finance.write_off_charge!(Finance.charge_for(appointment.id), actor: @staff)
      assert charge.status == :written_off

      kinds = kinds_for(appointment.id)
      assert :charge_written_off in kinds
      # The completion stands untouched — corrections are rows.
      assert Enum.count(kinds, &(&1 == :visit_completed)) == 1

      [write_off] = Enum.filter(events_for(appointment.id), &(&1.action == :charge_written_off))
      assert write_off.data["amount"] == "175"
      assert write_off.delivery_key == "clinic.charge_written_off:#{appointment.id}"
    end
  end

  # ── the PII pin ─────────────────────────────────────────────────────────

  describe "the PII posture" do
    test "patient names and clinical notes never appear in event data", %{versions: _versions} do
      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type()

      %{appointment: appointment} = back_dated_visit(patient, vet, type)

      for event <- events_for(appointment.id) do
        encoded = Jason.encode!(event.data)

        refute encoded =~ patient.name
        refute encoded =~ "Wired up for the wiring test"
        refute encoded =~ to_string(patient.owner_email)
        refute encoded =~ "reason"
        refute encoded =~ "notes"
      end
    end
  end

  # ── undeployed mappings step aside ──────────────────────────────────────

  describe "without deployed mappings" do
    @tag undeployed: true
    test "the lifecycle still walks — no active version, no event, no breakage" do
      # This test's subject is the undeployed world: no ACTIVE version for
      # any kind. A seeded database carries committed active versions that
      # every sandbox sees, so the test demotes them itself — the same
      # state `install!/0` has never run in.
      alias ClinicDemo.BusinessEvents.MappingVersion

      for version <- MappingVersion |> Ash.read!(authorize?: false),
          version.status == :active do
        Ash.update!(version, %{}, action: :demote, authorize?: false)
      end

      %{vet: vet, patient: patient} = fixtures()
      type = catalogue_type()

      {:ok, appointment} =
        Scheduling.book_appointment(
          %{
            patient_id: patient.id,
            clinician_id: vet.id,
            appointment_type_id: type.id,
            scheduled_at: tomorrow_at_hour(11),
            duration_minutes: 30,
            reason: "Undeployed walk",
            severity: 2
          },
          actor: @staff
        )

      {:ok, cancelled} =
        Scheduling.cancel_appointment(appointment, "Plans changed", actor: @staff)

      assert cancelled.status == :cancelled
      assert events_for(appointment.id) == []
    end
  end
end
