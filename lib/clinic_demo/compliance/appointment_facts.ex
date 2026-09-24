defmodule ClinicDemo.Compliance.AppointmentFacts do
  @moduledoc """
  The appointment fact builder: how an appointment record becomes the triples
  the active rule bundle probes.

  Modeled on the guard's fact construction
  (`ClinicDemo.Scheduling.Changes.ComplianceGuard.facts/2`) — same subject
  spelling, same precomputed policy predicates — but read-side: there is no
  changeset here, so facts come off the record alone. This is the builder
  `AshCompliance.status_for/2` drives when a surface asks "is this
  appointment compliant?" without attempting a transition.

  The contract (`AshCompliance.FactBuilder`) is worth restating where it
  bites:

    * the subject is the string `"appointment"`, deliberately not the atom —
      a bundle's predicates travel the compliance control plane as JSON, and
      the DSL's `has(:appointment, ...)` arrives back as "appointment";
    * every predicate below is declared in the active bundle's fact schema
      (`ClinicDemo.Compliance.AppointmentRules`); anything else fails the
      evaluation with an error naming the fix;
    * facts are precomputed policy, not raw storage — `true`/`false` answers,
      never weights or timestamps;
    * omission is meaningful, so every predicate is emitted under both spellings.

  The one vocabulary addition against the guard: the transition under
  question arrives in `opts` as `:transition_to`. The status surfaces pass
  `transition_to: :checked_in` — "would check-in be refused?" — because every
  rule in the seeded bundle gates on a transition, and check-in is the gate a
  row badge answers for.
  """

  @behaviour AshCompliance.FactBuilder

  @subject "appointment"

  @impl true
  def facts(appointment, opts) do
    [
      {@subject, :transition_to, Keyword.fetch!(opts, :transition_to)},
      {@subject, :patient_weight_recorded, weight_recorded?(appointment)},
      {@subject, :has_triage_urgency, not is_nil(appointment.triage_urgency)},
      {@subject, :has_notes, notes_present?(appointment)}
    ]
  end

  # The status paths preload :patient (the batched calculation declares the
  # load, so the whole page costs one patient query), and anything short of a
  # real weight value on a loaded patient falls back to the same headless
  # load the guard uses. That fallback is not an optimization nicety: a
  # partially-loaded patient (a relationship struct whose attributes are
  # still `Ash.NotLoaded`) would otherwise read its weight as "present" —
  # `not is_nil/1` is true for a NotLoaded marker — and a missing weight
  # must read as missing, never as compliant.
  defp weight_recorded?(%{patient: %{weight_kg: %Ash.NotLoaded{}}} = appointment),
    do: weight_recorded_via_load?(appointment)

  defp weight_recorded?(%{patient: %Ash.NotLoaded{}} = appointment),
    do: weight_recorded_via_load?(appointment)

  defp weight_recorded?(%{patient: %{weight_kg: nil}}), do: false
  defp weight_recorded?(%{patient: %{weight_kg: _weight}}), do: true

  # No relationship struct at all (a map-shaped record, a projection).
  defp weight_recorded?(appointment), do: weight_recorded_via_load?(appointment)

  defp weight_recorded_via_load?(appointment) do
    case Ash.load(appointment, :patient, authorize?: false) do
      {:ok, %{patient: %{weight_kg: weight}}}
      when not is_nil(weight) and not is_struct(weight, Ash.NotLoaded) ->
        true

      _missing_or_failed ->
        false
    end
  end

  # Read-side only: the guard also reads the write's :notes argument, but a
  # status query has no argument — the attribute is the truth here. The
  # attribute is set in the same action that carries the argument, so by the
  # time a status query can see a completed appointment, the attribute is
  # what the consult actually wrote.
  defp notes_present?(%{notes: notes}) when notes in [nil, ""], do: false
  defp notes_present?(%{notes: _}), do: true
end
