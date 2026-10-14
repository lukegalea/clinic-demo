defmodule ClinicDemo.Judgments.FactHostTest do
  @moduledoc """
  P4-S4: the clinic's first `ash_judgments` facts host, proven where it
  lives.

    * the host is TEMPORAL — writes split and truncate periods at
      `effective_at`, a plain read is the as-of-now read, and history is
      preserved in closed periods (the VPM-51 born-temporal demonstrations,
      replayed against the clinic's own table);
    * the admission path (`Triage.admit/3`) walks extract → record →
      admit and materialises a grant-grade patient-acuity fact;
    * C1 — the evidence assertion is ACTIVE on that path: the fact's
      recorded digest is the observation's `state_digest` (proven by
      reading both back), a divergent citation raises
      `AshJudgments.Facts.Errors.EvidenceMismatch` and writes nothing,
      and the nil-or-absent-reference path stays untouched;
    * the admission policy the materialiser enforces: a person-admitted
      fact is never overwritten or lowered by an automation pass, and an
      identical re-admission is idempotent.

  Everything runs in the sandbox (rolled back per test), the event log
  rows included — nothing here commits.
  """

  use ClinicDemo.DataCase, async: false

  alias AshJudgments.Facts.Errors.EvidenceMismatch
  alias AshJudgments.Facts.Materialiser
  alias ClinicDemo.Judgments.Fact
  alias ClinicDemo.Judgments.Observation
  alias ClinicDemo.Judgments.Triage
  alias ClinicDemo.Scheduling

  @staff %{id: "00000000-0000-0000-0000-0000000000cc", role: :veterinarian}

  @t1 ~U[2026-01-10 00:00:00Z]
  @t2 ~U[2026-03-01 00:00:00Z]
  @t3 ~U[2026-06-01 00:00:00Z]

  # A short window over the schedule: everything books tomorrow, so no
  # NotInThePast refusal, and every test's writes stay inside the sandbox.
  defp booked(opts \\ []) do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Judgment Vet",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    patient =
      if patient_id = opts[:patient_id] do
        Scheduling.get_patient!(patient_id)
      else
        Scheduling.register_patient!(
          %{
            name: Keyword.get(opts, :patient_name, "Judgment Animal"),
            species: :dog,
            owner_email: "judgment-#{System.unique_integer([:positive])}@example.com"
          },
          actor: @staff
        )
      end

    if weight = opts[:weight_kg], do: Scheduling.record_weight!(patient, weight, actor: @staff)

    Scheduling.get_appointment!(
      Scheduling.book_appointment!(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          reason: Keyword.get(opts, :reason, "Judgment check"),
          severity: Keyword.get(opts, :severity, 2)
        },
        actor: @staff
      ).id
    )
  end

  # --- the temporal lifecycle -----------------------------------------------------

  test "writes split and truncate periods at effective_at; a plain read is now" do
    appointment = booked()
    patient_id = appointment.patient_id

    assert {:ok, :materialised} = Triage.admit(appointment, :urgent, effective_at: @t1)
    assert {:ok, :materialised} = Triage.admit(appointment, :routine, effective_at: @t2)

    assert at(patient_id, @t1 |> DateTime.add(1, :hour)).value == "urgent"
    assert at(patient_id, @t2 |> DateTime.add(1, :hour)).value == "routine"
    assert current(patient_id).value == "routine"

    # Truncate at a third instant: the predicate returns to unknown from
    # there; history is preserved as two closed periods.
    fact = current(patient_id)

    fact
    |> Ash.Changeset.for_destroy(:truncate, %{}, as_of: @t3, authorize?: false)
    |> Ash.destroy!(authorize?: false)

    refute current(patient_id)
    assert periods(patient_id) |> length() == 2
  end

  test "an as-of read only returns the version valid at that instant" do
    appointment = booked()
    patient_id = appointment.patient_id

    assert {:ok, :materialised} = Triage.admit(appointment, :soon, effective_at: @t1)

    # Before the fact: no row at all — never "the later answer leaking back".
    refute at(patient_id, @t1 |> DateTime.add(-1, :hour))
    # After it: the contained version.
    assert at(patient_id, @t1 |> DateTime.add(1, :hour)).value == "soon"
    # A revision back-dated between: containment moves with the period.
    assert {:ok, :materialised} = Triage.admit(appointment, :emergency, effective_at: @t2)
    assert at(patient_id, @t1 |> DateTime.add(1, :hour)).value == "soon"
    assert at(patient_id, @t2 |> DateTime.add(1, :hour)).value == "emergency"
  end

  # --- the admission path -----------------------------------------------------------

  test "Triage.admit records the observation and materialises the acuity fact" do
    appointment = booked(weight_kg: Decimal.new("12.4"), severity: 4)

    assert {:ok, :materialised} = Triage.admit(appointment, :urgent)

    fact = current(appointment.patient_id)

    assert fact.subject == Triage.subject(appointment.patient_id)
    assert fact.subject_id == appointment.patient_id
    assert fact.predicate == Triage.question_id()
    assert fact.value == "urgent"
    assert fact.holds == true
    assert fact.admission_grade == :grant

    # The evidence chain, read back through the ledger: the admitted
    # fact carries the digest of the state the judgment saw, and that
    # digest is the cited observation's recorded state_digest. This is
    # the C1 assertion proven on the clinic's own tables.
    observation = Ash.get!(Observation, fact.admission_id, authorize?: false)

    assert observation.subject_id == appointment.patient_id
    assert observation.answer_kind == :choice
    assert observation.value == "urgent"
    assert observation.state_ref == %{"appointment_id" => appointment.id}
    assert observation.region == "ca"

    assert fact.subject_state_digest == observation.state_digest

    %{state_digest: digest, state: state} = Triage.extract(appointment)

    assert observation.state_digest == digest

    assert state == %{
             "severity" => 4,
             "reason" => "Judgment check",
             "weight_kg" => Decimal.new("12.4")
           }
  end

  test "a second visit revises the patient's acuity at the later instant" do
    first = booked(severity: 2)

    # Same patient, second visit: the fact is about the animal, so the
    # second visit's judgment revises the SAME predicate line.
    second = booked(patient_id: first.patient_id, severity: 5, reason: "Got worse")

    assert {:ok, :materialised} = Triage.admit(first, :soon, effective_at: @t1)
    assert {:ok, :materialised} = Triage.admit(second, :emergency, effective_at: @t2)

    assert current(first.patient_id).value == "emergency"

    periods = periods(first.patient_id)

    assert [
             %{"value" => "soon", "lower" => lower1, "upper" => upper1},
             %{"value" => "emergency", "lower" => lower2, "upper" => :unbounded}
           ] = periods

    assert DateTime.compare(lower1, @t1) == :eq
    assert DateTime.compare(upper1, @t2) == :eq
    assert DateTime.compare(lower2, @t2) == :eq
  end

  test "an identical re-admission is idempotent" do
    appointment = booked()

    assert {:ok, :materialised} = Triage.admit(appointment, :urgent, effective_at: @t1)
    assert {:ok, :unchanged} = Triage.admit(appointment, :urgent, effective_at: @t1)

    # One period, still the first admission's.
    assert [%{"value" => "urgent"}] = periods(appointment.patient_id)
  end

  # --- C1: the evidence assertion ----------------------------------------------------

  test "a divergent citation raises EvidenceMismatch and writes nothing" do
    appointment = booked()
    {:ok, observation} = Triage.record(appointment, :urgent)

    forged_digest = "sha256:" <> String.duplicate("f", 64)

    error =
      assert_raise EvidenceMismatch, fn ->
        Materialiser.materialise(
          %{
            result: :admitted,
            subject: Triage.subject(appointment.patient_id),
            predicate: Triage.question_id(),
            value: "urgent",
            holds: true,
            grade: :grant,
            admission_id: observation.id,
            subject_state_digest: forged_digest,
            effective_at: @t1,
            evidence_observation_id: observation.id
          },
          resource: Fact
        )
      end

    assert error.predicate == Triage.question_id()
    assert error.expected == observation.state_digest
    assert error.recorded == forged_digest

    # Nothing written — the assertion is pre-transaction.
    refute current(appointment.patient_id)
  end

  test "the preloaded-struct citation path asserts and passes identically" do
    appointment = booked()
    {:ok, observation} = Triage.record(appointment, :soon)

    assert {:ok, :materialised} =
             Materialiser.materialise(
               %{
                 result: :admitted,
                 subject: Triage.subject(appointment.patient_id),
                 predicate: Triage.question_id(),
                 value: "soon",
                 holds: true,
                 grade: :grant,
                 admission_id: observation.id,
                 subject_state_digest: observation.state_digest,
                 effective_at: @t1,
                 evidence_observation: observation
               },
               resource: Fact
             )

    assert current(appointment.patient_id).subject_state_digest == observation.state_digest
  end

  test "a nil-or-absent reference skips the assertion entirely" do
    appointment = booked()

    # The provable-only path: no citation, no ledger read, the write lands.
    assert {:ok, :materialised} =
             Materialiser.materialise(
               %{
                 result: :admitted,
                 subject: Triage.subject(appointment.patient_id),
                 predicate: Triage.question_id(),
                 value: "routine",
                 holds: true,
                 grade: :grant,
                 admission_id: Ash.UUID.generate(),
                 subject_state_digest: "sha256:" <> String.duplicate("3", 64),
                 effective_at: @t1
               },
               resource: Fact
             )

    assert current(appointment.patient_id).value == "routine"
  end

  # --- the admission policy -----------------------------------------------------------

  test "a person-admitted fact is never overwritten by an automation pass" do
    appointment = booked()
    patient_id = appointment.patient_id

    assert {:ok, :materialised} = Triage.admit(appointment, :routine, effective_at: @t1)

    # The vet's own verdict: person grade, supersedes freely.
    assert {:ok, :materialised} =
             Materialiser.materialise_verdict(%{
               subject: Triage.subject(patient_id),
               predicate: Triage.question_id(),
               value: "urgent",
               holds: true,
               admission_id: Ash.UUID.generate(),
               subject_state_digest: current(patient_id).subject_state_digest,
               effective_at: @t2
             })

    assert current(patient_id).value == "urgent"
    assert current(patient_id).admission_grade == :person

    # The next automation pass neither overwrites nor lowers it.
    assert {:ok, :kept_person_fact} = Triage.admit(appointment, :routine, effective_at: @t3)
    assert current(patient_id).value == "urgent"
    assert current(patient_id).admission_grade == :person
  end

  test "an omission truncates the open period and returns the predicate to unknown" do
    appointment = booked()
    patient_id = appointment.patient_id

    assert {:ok, :materialised} = Triage.admit(appointment, :soon, effective_at: @t1)

    assert {:ok, :superseded} =
             Materialiser.materialise(
               %{
                 result: :omitted,
                 subject: Triage.subject(patient_id),
                 predicate: Triage.question_id(),
                 grade: :grant,
                 effective_at: @t2
               },
               resource: Fact
             )

    refute current(patient_id)
    # History preserved: the fact is closed, not deleted.
    assert [%{"upper" => upper}] = periods(patient_id)
    assert DateTime.compare(upper, @t2) == :eq
  end

  # --- probes -------------------------------------------------------------------------

  defp current(patient_id) do
    Fact
    |> Ash.Query.for_read(:for_subject, %{
      subject: Triage.subject(patient_id),
      predicate: Triage.question_id()
    })
    |> Ash.read_one!(authorize?: false)
  end

  defp at(patient_id, as_of) do
    Fact
    |> Ash.Query.for_read(:for_subject, %{
      subject: Triage.subject(patient_id),
      predicate: Triage.question_id()
    })
    |> Ash.Query.as_of(as_of)
    |> Ash.read_one!(authorize?: false)
  end

  # The closed-period history is not an as-of read — counting the periods
  # (the WITHOUT OVERLAPS identity's real content) needs the range bounds,
  # so this probe speaks to the repo directly, the VPM-51 test's way.
  defp periods(patient_id) do
    ClinicDemo.Repo.query!(
      """
      select value::text, lower(valid_at)::text,
             coalesce(upper(valid_at)::text, 'unbounded')
      from judgment_facts
      where subject_id = $1 and predicate = $2
      order by lower(valid_at)
      """,
      [patient_id, Triage.question_id()]
    ).rows
    |> Enum.map(fn [value, lower, upper] ->
      decoded = if is_binary(value), do: Jason.decode(value), else: {:ok, value}

      norm = fn inst ->
        inst |> String.replace(" ", "T") |> String.replace("+00", "Z")
      end

      %{
        "value" => elem(decoded, 1),
        "lower" => to_dt(norm.(lower)),
        "upper" => if(upper == "unbounded", do: :unbounded, else: to_dt(norm.(upper)))
      }
    end)
  end

  defp to_dt(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    dt
  end
end
