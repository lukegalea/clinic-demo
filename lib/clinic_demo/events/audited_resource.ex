defmodule ClinicDemo.Events.AuditedResource do
  @moduledoc """
  The `:base` seam for package-base resources that belong in the audit feed.

  `ash_decisions` and `ash_bpmn` let a host swap the `use Ash.Resource` call
  at the top of their generated resources (`base:` / `base_opts:`). This
  module is that swap for exactly one purpose: attaching `AshEvents.Events`
  so the resource's writes append to the event log like every host-owned
  resource's do. Everything else mirrors what the packages emit by default
  (Postgres data layer, policy authorizer) — the packages stop emitting those
  once a base is set, so the base owns them.

  Used today by `ClinicDemo.Decisions.Evaluation`; the BPMN resources
  deliberately stay out (the process engine keeps its own `bpmn_process_events`
  trail, and duplicating it in the log would be a second opinion, not an
  audit).
  """

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)

    quote do
      use Ash.Resource,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshEvents.Events]
    end
  end
end
