defmodule ClinicDemo.BusinessEvents.Publish do
  @moduledoc """
  The bridge from clinic moments to the value ledger (BPSim BD-2): build
  the string-keyed observation payload for a moment, run the **active**
  `MappingVersion` over it, and `record!` the canonical event.

  One module, on purpose (design §2a): the change modules on the lifecycle
  actions are five-line declarations that hand this bridge the record and
  the changeset; every bit of payload-building, PII posture (ids and money
  only, never names or notes), and provenance plumbing lives here so it
  has exactly one home.

  Every row this bridge writes carries the same descriptors (design §2a):
  `subject_type: "clinic.visit"`, `subject_external_id` = the appointment
  id, `region: :clinic`, `residency_tag: "ca"`, `occurred_at` = the
  write's `as_of` (truth time — the seeds back-date it), `observed_at` =
  the wall clock (the ledger attribute's own default — when the clinic
  knew), `delivery_key` = `"clinic.<kind>:<appointment_id>"` so the
  seeds' double-walks (back-dated write plus the present-tense re-assert)
  collapse to one event, the same "one charge per visit, ever" ruling.

  ## Undeployed mappings step aside

  With no active mapping version for a kind (before `install!/0` has run
  — a fresh database before its first seed), the hook records nothing:
  that is the pre-ledger world, not a broken one. Everything else is
  loud: a mapping that cannot apply, or an append that fails, raises
  inside the visit's own transaction — a visit and its value event exist
  together or not at all, the `RecognizeCharge` atomicity carried over.
  """

  alias ClinicDemo.BusinessEvents.Ledger
  alias ClinicDemo.BusinessEvents.MappingVersion
  alias ClinicDemo.Finance
  alias ClinicDemo.Scheduling.AppointmentType

  @region :clinic
  @residency "ca"
  @subject_type "clinic.visit"

  @doc "The booking: expected value at catalogue price, the slot, the severity."
  def visit_booked(changeset, appointment) do
    publish(:visit_booked, appointment.id, fn ->
      base = %{
        "occurred_at" => as_of(changeset),
        "appointment_id" => appointment.id,
        "patient_id" => appointment.patient_id,
        "clinician_id" => appointment.clinician_id,
        "appointment_type_id" => appointment.appointment_type_id,
        "scheduled_at" => appointment.scheduled_at,
        "severity" => appointment.severity
      }

      # The catalogue price at booking — absent for a pre-catalogue visit,
      # the same no-type posture the recognition hook takes.
      case appointment.appointment_type_id do
        nil ->
          base

        type_id ->
          type = Ash.get!(AppointmentType, type_id, authorize?: false)
          Map.put(base, "base_price", type.base_price)
      end
    end)
  end

  @doc "The triage answer: the decision's weight, banded by the mapping's decode."
  def visit_triaged(changeset, appointment) do
    publish(:visit_triaged, appointment.id, fn ->
      %{
        "occurred_at" => as_of(changeset),
        "appointment_id" => appointment.id,
        "urgency" => to_string(appointment.triage_urgency),
        "severity" => appointment.severity
      }
    end)
  end

  @doc """
  The write-up: the recognized charge as realized value. Reads
  `Finance.charge_for/1` — after `RecognizeCharge` in the same
  transaction, so the charge is already there when a type exists. A
  visit with no catalogue type recognizes nothing, and its completion
  event simply carries no amount key (the mapping's absent-path
  semantics).
  """
  def visit_completed(changeset, appointment) do
    publish(:visit_completed, appointment.id, fn ->
      base = %{
        "occurred_at" => as_of(changeset),
        "appointment_id" => appointment.id,
        "recognized_at" => as_of(changeset)
      }

      case Finance.charge_for(appointment.id) do
        nil -> base
        charge -> Map.put(base, "amount", charge.amount)
      end
    end)
  end

  @doc "The story's losses: a cancellation carries the reason the desk gave."
  def visit_cancelled(changeset, appointment) do
    publish(:visit_cancelled, appointment.id, fn ->
      %{
        "occurred_at" => as_of(changeset),
        "appointment_id" => appointment.id,
        "reason" => appointment.cancellation_reason
      }
    end)
  end

  @doc "A no-show carries nothing but the fact."
  def visit_no_show(changeset, appointment) do
    publish(:visit_no_show, appointment.id, fn ->
      %{"occurred_at" => as_of(changeset), "appointment_id" => appointment.id}
    end)
  end

  @doc """
  The charge revision: written-off money is a new event, never a rewrite
  of the completion (§2a — value revisions are events).
  """
  def charge_written_off(changeset, charge) do
    publish(:charge_written_off, charge.appointment_id, fn ->
      %{
        "occurred_at" => as_of(changeset),
        "appointment_id" => charge.appointment_id,
        "amount" => charge.amount
      }
    end)
  end

  # ── the one write path ──────────────────────────────────────────────────

  defp publish(kind, subject_id, payload_fn) do
    case AshDiscreteBusinessEvents.Mappings.active_version(MappingVersion, kind) do
      nil ->
        # Undeployed: no active version for this kind, no event. See the
        # moduledoc — install!/0 deploys the rules before any booking.
        :ok

      version ->
        {:ok, canonical} = AshDiscreteBusinessEvents.Mappings.run(version, payload_fn.())

        Ledger.record!(
          %{
            event_kind: canonical.event_kind,
            region: @region,
            residency_tag: @residency,
            subject_type: @subject_type,
            subject_external_id: subject_id,
            occurred_at: canonical.occurred_at,
            delivery_key: "clinic.#{kind}:#{subject_id}",
            provenance: canonical.provenance,
            data: canonical.data
          },
          authorize?: false
        )

        :ok
    end
  end

  # The completion's own instant — `as_of` when the write was back-dated
  # (the seeded history), now when it was not. Same rule the temporal
  # machinery itself uses to start the period, and the same resolution
  # `RecognizeCharge` uses for the charge's `recognized_at`.
  defp as_of(changeset) do
    case changeset.as_of do
      %DateTime{} = as_of -> as_of
      _ -> DateTime.utc_now()
    end
  end
end
