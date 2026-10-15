defmodule ClinicDemo.BusinessEvents.Ledger do
  @moduledoc """
  The clinic's value ledger — a BIZEV `{:ledger, opts}` instantiation on
  this app's own base, so the policies below govern its actions natively.

  Every row is a canonical discrete business event (the §1.4 shape): the
  subject and actor ride as descriptors, never foreign keys; `occurred_at`
  (the write's `as_of` — truth time), `observed_at` (the wall clock — when
  the clinic knew) and `sequence` (commit order, per region) are three
  clocks answering three questions; `provenance` points into the active
  `ClinicDemo.BusinessEvents.MappingVersion` row that produced the row's
  `data`; corrections are new rows (`supersedes_event_id`), never rewrites;
  `delivery_key` makes a repeat write collapse to the existing row.

  The machinery is the package's, not ours: the `record` path takes a
  per-region advisory lock before insert (so sequence order is commit
  order), a `BEFORE INSERT` trigger chains each region's rows with
  SHA-256 (`mix bizev.verify_chains --resource ... --region clinic`), an
  immutability trigger refuses UPDATE and DELETE at the database, and the
  stock `create` that AshEvents would add is removed — the only write
  path is `record`.

  The declaration also emits the simulation twin,
  `ClinicDemo.BusinessEvents.Ledger.SimulationEvent` (same columns, own
  table `business_event_simulation_events`, own chains; every row carries
  `simulated: true` and a `simulation_run` label). A simulated event
  cannot reach a real projector or a real read — the isolation is the
  module, not a filter anyone must remember.
  """

  use Ash.Resource,
    domain: ClinicDemo.BusinessEvents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.EventLog, AshDiscreteBusinessEvents.Ledger.Extension]

  use AshDiscreteBusinessEvents.Resources,
      {:ledger,
       repo: ClinicDemo.Repo,
       table: "business_event_ledger",
       simulation_table: "business_event_simulation_events",
       domain: ClinicDemo.BusinessEvents}

  policies do
    policy action_type(:read) do
      description "The ledger is readable by anything that can reach the application — same posture as the books."
      authorize_if always()
    end

    policy action(:record) do
      description """
      Recording a value event is attributed like every write in this app.
      The lifecycle hooks (BD-2) call with `authorize?: false` — the
      `RecognizeCharge` precedent — because a visit and its value event
      exist together or not at all, inside the visit's own transaction.
      """

      authorize_if actor_present()
    end

    policy action(:append) do
      description """
      The locked internal insert, reachable only through `record` (which
      hands it the caller's context) — so it rides `record`'s gate: an
      actor present, or an unauthorized machinery call. Nothing else in
      the application may address it, and the stock `create` is gone.
      """

      authorize_if actor_present()
    end

    # No policy applies to `cross_region_read` (the alarmed operator
    # door): under the policy authorizer an unmentioned action is
    # forbidden for authorized calls, and the clinic has no cross-region
    # question to ask one region's chain.
  end
end
