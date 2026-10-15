defmodule ClinicDemo.BusinessEvents.Declarations do
  @moduledoc """
  The BIZEV declarations for the clinic's value events: one internal
  source and the six mappings the design pins, in the kinds' lifecycle
  order (booked → triaged → completed → cancelled / no_show, plus the
  charge's write-off).

  This module is the Spark DSL host and deliberately NOT the Ash domain —
  a module can carry only one Spark DSL, and `use AshDiscreteBusinessEvents`
  inside the domain module would overwrite the surface Ash's own
  `__before_compile__` generates (`default_short_name/0` and friends).
  `ClinicDemo.BusinessEvents` is the domain; this module is what
  `Mappings.publish/3` compiles against.

  The source is declaration-only (`adapter: nil`, verifier-legal): the
  clinic's own temporal resources ARE the raw layer, and nothing ever
  syncs `:clinic_core`. The demo's honesty rule rides with it — these
  events are internal clinic history, never presented as external SaaS
  data.

  Payload paths below are the raw observation keys `Publish` (BD-2) will
  build — ids and money only, never names or notes — and the canonical
  targets are what the ledger rows' `data` will carry.
  """

  use AshDiscreteBusinessEvents, domains: [ClinicDemo.BusinessEvents]

  business_events do
    source :clinic_core do
      # Declaration-only: the clinic's own temporal resources ARE the raw
      # layer; nothing ever syncs this source (adapter: nil is
      # verifier-legal).
      region(:clinic)

      stream(:appointment, select: "appointment lifecycle observations, built by Publish")
    end

    # The catalogue price at booking — value as expectation — plus the two
    # forecast dimensions (BD-3's projection folds them into the rates
    # table). Both are absent-path: a pre-catalogue booking carries no
    # price and no type.
    mapping :visit_booked do
      source {:clinic_core, :appointment}

      map(:occurred_at, from: "occurred_at", type: :utc_datetime_usec)
      map(:expected_amount, from: "base_price", type: :decimal)
      map(:scheduled_at, from: "scheduled_at", type: :utc_datetime)
      map(:severity, from: "severity", type: :integer)
      map(:clinician_id, from: "clinician_id", type: :uuid)
      map(:type_id, from: "appointment_type_id", type: :uuid)

      constant(:source_system, value: "clinic_core")

      unmapped_because(:patient_name, "PII — stays in the record")
    end

    # The one decode: a decision's weight, banded from the urgency.
    mapping :visit_triaged do
      source {:clinic_core, :appointment}

      map(:occurred_at, from: "occurred_at", type: :utc_datetime_usec)
      map(:urgency, from: "urgency", type: :string)
      map(:severity, from: "severity", type: :integer)

      decode(:urgency_band,
        from: "urgency",
        cases: %{
          "emergency" => "high",
          "urgent" => "high",
          "soon" => "medium",
          "routine" => "low"
        }
      )

      constant(:source_system, value: "clinic_core")
    end

    # The recognized charge. `amount` is absent-path: a completion with no
    # catalogue type writes no amount key at all — no silent nil.
    mapping :visit_completed do
      source {:clinic_core, :appointment}

      map(:occurred_at, from: "occurred_at", type: :utc_datetime_usec)
      map(:amount, from: "amount", type: :decimal)

      constant(:source_system, value: "clinic_core")
    end

    # Value as story: expected → realized or lost. Cancellations carry the
    # reason the front desk gave; no-shows carry nothing but the fact.
    mapping :visit_cancelled do
      source {:clinic_core, :appointment}

      map(:occurred_at, from: "occurred_at", type: :utc_datetime_usec)
      map(:reason, from: "reason", type: :string)

      constant(:source_system, value: "clinic_core")
    end

    mapping :visit_no_show do
      source {:clinic_core, :appointment}

      map(:occurred_at, from: "occurred_at", type: :utc_datetime_usec)

      constant(:source_system, value: "clinic_core")
    end

    # A value revision is a new event, never a rewrite of an old one.
    mapping :charge_written_off do
      source {:clinic_core, :appointment}

      map(:occurred_at, from: "occurred_at", type: :utc_datetime_usec)
      map(:amount, from: "amount", type: :decimal)

      constant(:source_system, value: "clinic_core")
    end
  end
end
