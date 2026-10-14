defmodule ClinicDemo.Scheduling.Changes.AdmitAcuityFact do
  @moduledoc """
  The judgment half of a triage write (P4-S5): recording the triage answer
  on the visit also ADMITS the patient-acuity fact, in the same transaction
  as the recording itself.

  This is the integration point where the scheduling domain hands the
  judged answer to the judgment pipeline. `:record_triage` is the one door
  every triage answer walks through — the BPMN invoker, the decision
  task-list, the seeds — so the hook makes the observation ledger and the
  fact table accumulate wherever triage happens, without any caller having
  to know the facts substrate exists. The division of labor is the
  architecture's own line: a decision decides, scheduling acts, and
  `ClinicDemo.Judgments` keeps the record — `Judgments.Triage.admit/3`
  (extract → record → admit) does all three steps, citing its observation
  by id, so C1's evidence assertion is active on every path that reaches
  here.

  Four properties worth naming:

  **Same transaction.** The admission runs in an `after_action` hook, like
  `RecognizeCharge`'s charge: a triage write and its admitted fact exist
  together or not at all. A triage whose judgment could not be admitted is
  a failed triage — the error (including C1's `EvidenceMismatch` on a
  divergent citation) fails the whole write rather than leaving a visit
  that claims an urgency no fact ever recorded.

  **A judgment is recorded once per visit.** The ledger is append-only,
  but the same answer for the same visit recorded twice is one judgment
  re-stated, not two judgments — the seeds' back-dated history walks
  re-assert the engine's triage answer at the history's instant (the
  appointment is temporal; the engine is not), and the hook steps aside
  when the ledger already carries this visit's judgment. That is the
  honest reading of the ledger too: a re-assertion into appointment
  history is appointment plumbing, not a new judgment, and the fact
  timeline keeps the instant the judgment actually happened. (This is
  also why the fact timeline opens at the booking — the temporal create
  can only OPEN a fact's first period, never back-insert one before an
  existing later period; the facts table honestly shows when the
  admission landed.)

  **Replay steps aside.** During an `ash_events` replay the hook does
  nothing: the event log already carries the observation's and the fact's
  own rows, and re-admitting here would append a second copy of each per
  replay pass. The cold clone rebuilds the judgment record from the log
  itself — which is the honest replay story, not a workaround.

  **The instant is the write's.** The fact's `effective_at` is the triage
  write's own `as_of` — `now` when the engine records at wall clock — so
  the fact's periods land where the visit's history says the judgments
  happened, and the standings reads agree with the appointment's history.
  """

  use Ash.Resource.Change

  # Temporal safety (declared): the hook reads no clock of its own — the
  # fact's instant is the write's `as_of`, already resolved onto the
  # changeset, and the extract's reads are of the same records the caller's
  # triage pointed at. Nothing here decides anything from "now".
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, appointment ->
      admit(changeset, appointment)
    end)
  end

  defp admit(changeset, appointment) do
    urgency = Ash.Changeset.get_argument(changeset, :urgency)

    cond do
      # Replay rebuilds the ledger and the fact from their own log rows;
      # re-admitting here would write a second observation per pass.
      changeset.context[:ash_events_replay?] ->
        {:ok, appointment}

      # The seeds' history walks re-assert an answer that is already on
      # the record — one judgment per visit and answer, not one per write.
      already_recorded?(appointment, urgency) ->
        {:ok, appointment}

      true ->
        ClinicDemo.Judgments.Triage.admit(appointment, urgency,
          effective_at: effective_at(changeset)
        )
        |> case do
          {:ok, _verdict} -> {:ok, appointment}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Does the ledger already carry this visit's judgment of this answer?
  # The observation's `state_ref` is the judgment's pointer at the visit
  # it judged, so the match is visit-scoped: another visit of the same
  # patient reaching the same answer is a new judgment, and records.
  defp already_recorded?(appointment, urgency) do
    ClinicDemo.Judgments.Observation
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      subject_id == ^appointment.patient_id and
        question_id == ^ClinicDemo.Judgments.Triage.question_id() and
        value == ^to_string(urgency)
    )
    |> Ash.read!(authorize?: false)
    |> Enum.any?(&(&1.state_ref == %{"appointment_id" => appointment.id}))
  end

  # The triage write's own instant — `as_of` when the write was back-dated
  # (a host reconstructing a judgment's instant), now when it was not (the
  # materialiser's own default). Same rule `RecognizeCharge` uses for the
  # charge's instant.
  defp effective_at(changeset) do
    case changeset.as_of do
      %DateTime{} = as_of -> as_of
      _ -> nil
    end
  end
end
