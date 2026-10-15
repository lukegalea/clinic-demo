defmodule ClinicDemo.BusinessEvents do
  @moduledoc """
  The clinic's value ledger domain (BPSim BD-1): the discrete business
  events the visit lifecycle produces, the mappings that shape them, and
  the artifacts those mappings are published as.

  Three resources, all BIZEV resource macros on this app's own base:

    * `Ledger` — the append-only, chained, delivery-idempotent event
      log (plus the `Ledger.SimulationEvent` twin its declaration
      emits, the structural half of sim isolation),
    * `MappingVersion` — the versioned, content-hashed mapping
      artifacts every ledger row's provenance points into.

  The declarations live beside the domain, in
  `ClinicDemo.BusinessEvents.Declarations` — the BIZEV fixture shape,
  because a module can carry only one Spark DSL (`use
  AshDiscreteBusinessEvents` in the domain module itself would overwrite
  the domain machinery Ash generates in its own `__before_compile__`).
  There the `business_events` block declares the clinic's one internal
  source and the six mapping rules the design pins (booked, triaged,
  completed, cancelled, no_show, written_off). The source is
  declaration-only: the clinic's own temporal resources ARE the raw
  layer, and nothing ever syncs `:clinic_core` (`adapter: nil` is
  verifier-legal) — these events are internal clinic history, and any
  surface showing them must say so.

  `install!/0` publishes each declared mapping and walks it to active
  before any booking writes an event. It is idempotent: the artifact's
  content hash IS the version's identity, so a re-run re-publishes to the
  same rows and activates nothing new. `mix seed` and the test suite both
  call it — the `ClinicDemo.Rules.install!/0` precedent.

  Region and grain, per the design: one region, `:clinic`; residency
  `\"ca\"`; events ride `subject_external_id` = the appointment id at
  subject grain (the projection's grain ruling is BD-3's deliverable, not
  this slice's).
  """

  use Ash.Domain

  alias ClinicDemo.BusinessEvents.Declarations
  alias ClinicDemo.BusinessEvents.Ledger
  alias ClinicDemo.BusinessEvents.MappingVersion

  resources do
    resource Ledger
    resource Ledger.SimulationEvent
    resource MappingVersion
  end

  @mapping_names [
    :visit_booked,
    :visit_triaged,
    :visit_completed,
    :visit_cancelled,
    :visit_no_show,
    :charge_written_off
  ]

  @doc "The mapping names the declarations declare, in declaration order."
  @spec mapping_names() :: [atom()]
  def mapping_names, do: @mapping_names

  @doc """
  Publishes every declared mapping and walks it draft → validate →
  activate. Idempotent: publishing an unchanged declaration returns the
  existing hash-identified version, and an already-active version is left
  alone — running this twice changes nothing.

  Called by `mix seed` and the test suite before any booking, so a ledger
  row's provenance always resolves to an active `MappingVersion`.
  """
  @spec install!() :: [MappingVersion.t()]
  def install! do
    Enum.map(@mapping_names, fn name ->
      {:ok, version} =
        AshDiscreteBusinessEvents.Mappings.publish(Declarations, name, MappingVersion)

      version =
        case version.status do
          :draft -> Ash.update!(version, %{}, action: :validate)
          _validated_or_active -> version
        end

      case version.status do
        :active -> version
        :validated -> AshDiscreteBusinessEvents.Mappings.activate!(version)
      end
    end)
  end
end
