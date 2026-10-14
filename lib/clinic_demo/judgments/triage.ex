defmodule ClinicDemo.Judgments.Triage do
  @moduledoc """
  The acuity admission path: the clinic's minimal judgment pipeline
  (P4-S4) — extract → record → admit.

  The triage decision decides how urgent an animal is; the scheduling
  domain writes the answer on the visit; this module is what turns that
  judged answer into a **fact**:

    1. **Extract** — the state projection the judgment saw (presenting
       severity, the owner's words, the weigh-in on record) and its
       canonical digest (`AshJudgments.Registry.Canonical.digest/1`).
       Pure and replay-identical: the digest is computed only from what
       the projection carried.
    2. **Record** — the observation (`Observation.record`, append-only,
       answer accepted as input): the judged urgency with its question
       identity and the state digest, so the ledger row is the evidence
       of what was judged on what.
    3. **Admit** — `AshJudgments.Facts.Materialiser.materialise/2`
       writes the patient-acuity fact (`Fact`) **citing the observation
       by id**. That citation is C1's opt-in evidence assertion, active
       from day one: the materialiser reads the observation back and
       refuses the write unless its recorded `state_digest` equals the
       decision's `subject_state_digest`. A stale or fabricated citation
       raises `AshJudgments.Facts.Errors.EvidenceMismatch` and nothing is
       materialised.

  The fact is about the **patient**, not the visit: a second visit
  revises the acuity fact at the new instant (a period split, history
  preserved), and an omission truncates it — the temporal lifecycle the
  fragment supplies. Admission is grant-grade: a human verdict path
  (`Materialiser.materialise_verdict/1`) supersedes it freely and is
  never overwritten by a later automation pass.

  The line this keeps with `Decisions` and `Scheduling`: a decision
  decides, scheduling acts, and this domain keeps the record. Nothing
  here re-derives an urgency — the caller passes the answer the rule
  gave, exactly as `Appointment.record_triage` does.
  """

  alias AshJudgments.Facts.Materialiser
  alias AshJudgments.Registry.Canonical
  alias ClinicDemo.Judgments.Fact
  alias ClinicDemo.Scheduling

  @typedoc "The urgency values the triage decision can answer."
  @type urgency :: :emergency | :urgent | :soon | :routine

  @urgencies [:emergency, :urgent, :soon, :routine]

  @question_version 1
  @family "clinic_triage"

  @question_id "judgment:v0:ClinicDemo.Scheduling.Patient#judgments/acuity"

  # The question's identity hash (§3.2): over exactly the identity object
  # — answer type, instructions, options in declaration order, the state
  # contract and the version. A changed threshold changes the DMN
  # document, not this question; a changed question is a new version.
  @question_hash Canonical.digest(%{
                   "answer_type" => "choice",
                   "criteria" => nil,
                   "instructions" =>
                     "How urgently does this animal need to be seen, per the clinic's triage table?",
                   "options" => Enum.map(@urgencies, &Atom.to_string/1),
                   "state_contract" => %{
                     "reason" => "string",
                     "severity" => "integer",
                     "weight_kg" => "decimal or null"
                   },
                   "version" => @question_version
                 })

  @doc "The judged question's id — the fact predicate's one namespace."
  @spec question_id() :: String.t()
  def question_id, do: @question_id

  @doc """
  The patient-acuity subject: the composite the set evaluator and the
  facts table key on.
  """
  @spec subject(patient_id :: String.t()) :: map()
  def subject(patient_id) do
    %{"type" => "ClinicDemo.Scheduling.Patient", "id" => patient_id}
  end

  @doc """
  The state projection the acuity judgment saw, and its digest.

  Reads the visit's presenting severity and reason plus the patient's
  weigh-in (loaded, so the projection is a pure function of the records —
  the same visit always extracts the same digest, which is what makes the
  C1 assertion meaningful rather than theatre).
  """
  @spec extract(ClinicDemo.Scheduling.Appointment.t()) :: %{
          state: map(),
          state_digest: String.t()
        }
  def extract(appointment) do
    patient = Scheduling.get_patient!(appointment.patient_id)

    state = %{
      "severity" => appointment.severity,
      "reason" => appointment.reason,
      "weight_kg" => patient.weight_kg
    }

    %{state: state, state_digest: Canonical.digest(state)}
  end

  @doc """
  Records the judgment: the observation row with the answer the rule gave
  and the extracted state digest. Append-only — a re-judgment is a new
  row, never an edit.
  """
  @spec record(ClinicDemo.Scheduling.Appointment.t(), urgency()) ::
          {:ok, ClinicDemo.Judgments.Observation.t()} | {:error, term()}
  def record(appointment, urgency) when urgency in @urgencies do
    %{state_digest: digest} = extract(appointment)

    ClinicDemo.Judgments.record_observation(%{
      question_id: @question_id,
      question_hash: @question_hash,
      question_version: @question_version,
      family: @family,
      subject_type: "ClinicDemo.Scheduling.Patient",
      subject_id: appointment.patient_id,
      state_digest: digest,
      state_ref: %{"appointment_id" => appointment.id},
      answer_kind: :choice,
      value: to_string(urgency),
      # The "instrument" here is the clinic's DMN table — a deterministic
      # rule, not a model call. Identity as the requested spec, never an
      # endpoint (§9); there are no probabilities to speak of, and a
      # deterministic answer carries no confidence figure.
      model_spec_requested: "clinic-demo:appointment-triage-rule",
      profile: "clinic_triage_local",
      mode: :live
    })
  end

  @doc """
  The whole path in one call: extract, record, admit.

  `opts`:

    * `:effective_at` — the instant the fact takes effect (backdating
      reconstructs history; default now, the materialiser's own default).

  Returns the materialiser's verdict — `:materialised`, `:unchanged`,
  `:kept_person_fact` — or the error. The evidence citation is never
  optional on this path: an admission without its observation is not an
  admitted judgment.
  """
  @spec admit(ClinicDemo.Scheduling.Appointment.t(), urgency(), keyword()) ::
          {:ok, :materialised | :unchanged | :kept_person_fact | :superseded | :no_fact}
          | {:error, term()}
  def admit(appointment, urgency, opts \\ []) when urgency in @urgencies do
    %{state_digest: digest} = extract(appointment)

    {:ok, observation} = record(appointment, urgency)

    decision = %{
      result: :admitted,
      subject: subject(appointment.patient_id),
      predicate: @question_id,
      value: to_string(urgency),
      holds: true,
      grade: :grant,
      admission_id: observation.id,
      subject_state_digest: digest,
      effective_at: opts[:effective_at],
      # C1: the assertion is the point. The materialiser reads this
      # observation pre-transaction and refuses the write unless the
      # recorded input hash equals the digest above.
      evidence_observation_id: observation.id
    }

    Materialiser.materialise(decision, resource: Fact)
  end
end
