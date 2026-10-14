defmodule ClinicDemo.Judgments.IntegrationTest do
  @moduledoc """
  P4-S5: the judgment substrate wired into the clinic's flow, proven where
  it lives.

    * **Admission integration e2e** — booking a visit runs the engine's
      triage (the DMN rule, then the `:record_triage` action), and the
      `AdmitAcuityFact` hook admits the fact in the same transaction:
      observation on the ledger, fact on the facts table, the C1 evidence
      chain readable straight off the booking. No test harness admits
      anything — the engine path is the path.
    * **One judgment per visit and answer** — re-recording the same answer
      (the seeds' back-dated history walks) steps aside; a changed answer
      records a new judgment and revises the fact.
    * **The surface reads are three-valued** — the `acuity_fact`
      calculation reads `AshJudgments.Query.status/4` and renders the
      tri-state distinctly: the admitted urgency, "ruled out", "no fact".
    * **The standings as-of variant** — `Standings.status_at/4` /
      `tri_state_at/4` over the facts' period containment, expiry
      evaluated at T, and the as-of-now read agreeing with the package's
      own `Query.status/4`.

  Everything runs in the sandbox (rolled back per test), the event log
  rows included — nothing here commits.
  """

  use ClinicDemo.DataCase, async: false

  require Ash.Query

  alias AshJudgments.Facts.Materialiser
  alias AshJudgments.Query
  alias ClinicDemo.Judgments.Fact
  alias ClinicDemo.Judgments.Observation
  alias ClinicDemo.Judgments.Standings
  alias ClinicDemo.Judgments.Triage
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.Calculations.AcuityFact

  @staff %{id: "00000000-0000-0000-0000-0000000000dd", role: :veterinarian}

  @t1 ~U[2026-01-10 00:00:00Z]
  @t2 ~U[2026-03-01 00:00:00Z]
  @t_mid ~U[2026-02-01 00:00:00Z]

  # Book a visit and, unlike the fact-host goldens, KEEP the booking's
  # auto-admitted fact — it is the integration under test here.
  defp booked(opts \\ []) do
    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Integration Vet",
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
            name: Keyword.get(opts, :patient_name, "Integration Animal"),
            species: :dog,
            owner_email: "integration-#{System.unique_integer([:positive])}@example.com"
          },
          actor: @staff
        )
      end

    if weight = opts[:weight_kg], do: Scheduling.record_weight!(patient, weight, actor: @staff)

    appointment =
      Scheduling.get_appointment!(
        Scheduling.book_appointment!(
          %{
            patient_id: patient.id,
            clinician_id: vet.id,
            scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
            reason: Keyword.get(opts, :reason, "Integration check"),
            severity: Keyword.get(opts, :severity, 2)
          },
          actor: @staff
        ).id
      )

    {appointment, patient}
  end

  # Like the goldens: a visit whose judgment record starts empty, so a
  # test can walk admissions at its own instants.
  defp booked_clear(opts \\ []) do
    {appointment, patient} = booked(opts)

    if fact = current(patient.id) do
      fact
      |> Ash.Changeset.for_destroy(:truncate, %{}, as_of: fact.valid_at.lower, authorize?: false)
      |> Ash.destroy!(authorize?: false)
    end

    {appointment, patient}
  end

  # --- the admission integration ---------------------------------------------------

  test "booking admits the engine's triage through the hook, with the C1 chain intact" do
    {appointment, patient} = booked()

    # The engine's synchronous triage wrote the answer on the visit...
    urgency = appointment.triage_urgency
    refute is_nil(urgency)

    # ...and the hook admitted it: one observation, one fact, the fact
    # citing the observation with its exact state digest (C1, read back).
    fact = current(patient.id)
    assert fact.value == to_string(urgency)
    assert fact.holds == true
    assert fact.admission_grade == :grant
    assert fact.subject == Triage.subject(patient.id)

    observation = Ash.get!(Observation, fact.admission_id, authorize?: false)
    assert observation.state_ref == %{"appointment_id" => appointment.id}
    assert observation.value == to_string(urgency)
    assert fact.subject_state_digest == observation.state_digest

    # The digest is the extract of the state the judgment saw.
    %{state_digest: digest} = Triage.extract(appointment)
    assert observation.state_digest == digest

    # The surface badge reads the admitted fact, not the attribute.
    assert acuity_of(appointment) == to_string(urgency)
  end

  test "re-recording the same answer steps aside; a changed answer re-judges" do
    {appointment, patient} = booked()
    urgency = appointment.triage_urgency

    observations_before = ledger_count(patient.id)

    # The seeds' history-walk shape: the same visit, the same answer,
    # re-recorded (back-dated or not) — one judgment, still.
    Scheduling.record_appointment_triage!(appointment, urgency, actor: @staff)
    assert ledger_count(patient.id) == observations_before

    # A changed answer is a new judgment: a new ledger row, and the fact
    # revises at the write's instant.
    retriage = Enum.find([:emergency, :urgent, :soon, :routine], &(&1 != urgency))

    Scheduling.record_appointment_triage!(appointment, retriage, actor: @staff)

    assert ledger_count(patient.id) == observations_before + 1

    fact = current(patient.id)
    assert fact.value == to_string(retriage)
    assert acuity_of(appointment) == to_string(retriage)
  end

  # --- the three-valued surface read -------------------------------------------------

  test "the acuity badge renders the tri-state distinctly" do
    {appointment, patient} = booked_clear()

    # Unknown: the judgment record has nothing to say.
    assert acuity_of(appointment) == AcuityFact.no_fact()

    # In: the admitted urgency, the fact's own value.
    assert {:ok, :materialised} = Triage.admit(appointment, :urgent)
    assert acuity_of(appointment) == "urgent"

    # Out: an admitted fact that says the predicate does not hold — the
    # refusal shape a person verdict writes, never the triage path.
    {:ok, observation} = Triage.record(appointment, :urgent)

    assert {:ok, :materialised} =
             Materialiser.materialise(
               %{
                 result: :admitted,
                 subject: Triage.subject(patient.id),
                 predicate: Triage.question_id(),
                 value: "urgent",
                 holds: false,
                 grade: :grant,
                 admission_id: observation.id,
                 subject_state_digest: observation.state_digest,
                 evidence_observation_id: observation.id
               },
               resource: Fact
             )

    assert acuity_of(appointment) == AcuityFact.ruled_out()

    # And the package's own tri-state partition agrees, three-valued:
    # this subject is out, a never-judged one is unknown — never folded.
    judged = Triage.subject(patient.id)
    stranger = Triage.subject("no-such-patient")

    assert %{
             in: [],
             out: [^judged],
             unknown: [{^stranger, :no_fact}]
           } = Query.tri_state(Fact, [judged, stranger], Triage.question_id())
  end

  # --- the standings as-of variant ---------------------------------------------------

  test "standings read the standing at T, off the period containment" do
    {appointment, patient} = booked_clear()
    subject = Triage.subject(patient.id)

    assert {:ok, :materialised} = Triage.admit(appointment, :soon, effective_at: @t1)
    assert {:ok, :materialised} = Triage.admit(appointment, :emergency, effective_at: @t2)

    # Before the first admission: unknown — never "the later answer
    # leaking back". (The period's lower bound is inclusive, so the probe
    # sits an hour before it.)
    assert {:unknown, :no_fact} =
             Standings.status_at(subject, Triage.question_id(), @t1 |> DateTime.add(-1, :hour))

    assert {:in, fact} = Standings.acuity_status_at(subject, @t1 |> DateTime.add(1, :hour))
    assert fact.value == "soon"

    assert {:in, fact} = Standings.acuity_status_at(subject, @t2 |> DateTime.add(1, :hour))
    assert fact.value == "emergency"

    # The partition at an instant, disjoint and covering.
    stranger = Triage.subject("no-such-patient")

    assert %{
             in: [^subject],
             out: [],
             unknown: [{^stranger, :no_fact}]
           } =
             Standings.tri_state_at(
               [subject, stranger],
               Triage.question_id(),
               @t2 |> DateTime.add(1, :hour)
             )

    # The as-of-now read agrees with the package's own Query.status —
    # the mirror lattice pinned against the original.
    {:in, standing_fact} = Standings.acuity_status_at(subject, DateTime.utc_now())
    {:in, query_fact} = Query.status(Fact, subject, Triage.question_id())
    assert standing_fact.id == query_fact.id
  end

  test "expiry is evaluated at T, not at the wall clock" do
    {appointment, patient} = booked_clear()
    subject = Triage.subject(patient.id)

    # A domain-validity window on the admission (declared per predicate;
    # the ledger row supplies the evidence).
    {:ok, observation} = Triage.record(appointment, :soon)

    assert {:ok, :materialised} =
             Materialiser.materialise(
               %{
                 result: :admitted,
                 subject: subject,
                 predicate: Triage.question_id(),
                 value: "soon",
                 holds: true,
                 grade: :grant,
                 admission_id: observation.id,
                 subject_state_digest: observation.state_digest,
                 effective_at: @t1,
                 valid_until: @t_mid,
                 evidence_observation_id: observation.id
               },
               resource: Fact
             )

    # Had not expired at T: in.
    assert {:in, _fact} = Standings.acuity_status_at(subject, @t1 |> DateTime.add(1, :hour))

    # Had expired by T: unknown, with the reason named.
    assert {:unknown, :expired} =
             Standings.acuity_status_at(subject, @t_mid |> DateTime.add(1, :hour))
  end

  # --- probes ------------------------------------------------------------------------

  defp current(patient_id) do
    Fact
    |> Ash.Query.for_read(:for_subject, %{
      subject: Triage.subject(patient_id),
      predicate: Triage.question_id()
    })
    |> Ash.read_one!(authorize?: false)
  end

  defp acuity_of(appointment) do
    Ash.load!(appointment, :acuity_fact, authorize?: false).acuity_fact
  end

  defp ledger_count(patient_id) do
    Observation
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(subject_id == ^patient_id)
    |> Ash.count!(authorize?: false)
  end
end
