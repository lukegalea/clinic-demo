defmodule ClinicDemo.BusinessEvents.MappingVersion do
  @moduledoc """
  The clinic's mapping artifacts, as data — a BIZEV `:mapping_version`
  instantiation on this app's own base.

  One row per compiled `business_events` declaration on
  `ClinicDemo.BusinessEvents`: the canonical artifact (the operators in
  declaration order) plus the content hash that is its identity. The
  lifecycle is draft → validate → activate — `validate` re-runs the
  compiler's structural checks over the stored artifact, `activate`
  freezes the version as its mapping name's active one (superseding the
  previous active, demoted — never rewritten). Content never changes
  after draft: a changed declaration mints a new version row.

  Every ledger row's `provenance` (`mapping_name` + `mapping_version_hash`)
  joins exactly one row here, so any value event points back into
  replayable rule data rather than a code revision.
  `ClinicDemo.BusinessEvents.install!/0` walks the lifecycle at seed time,
  idempotently: an unchanged declaration re-publishes to the same
  hash-identified version and re-activates nothing new.
  """

  use Ash.Resource,
    domain: ClinicDemo.BusinessEvents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  use AshDiscreteBusinessEvents.Resources, :mapping_version

  postgres do
    table "business_event_mapping_versions"
    repo ClinicDemo.Repo
  end

  policies do
    policy action_type(:read) do
      description "The rules are readable by anything that can reach the application — they are data, not secrets."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description """
      The lifecycle writes (draft → validate → activate, and the internal
      demote) are machinery writes: `Mappings.publish/3` and `install!/0`
      record compiled declarations, and there is no other sanctioned write
      path — no generic create, update or destroy exists to accept input
      (the macro ships only the lifecycle actions over frozen content).
      """

      authorize_if always()
    end
  end
end
