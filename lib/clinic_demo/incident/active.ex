defmodule ClinicDemo.Incident.Active do
  @moduledoc """
  A policy *condition* that is true while a named incident is switched on.

  It is used as `{ClinicDemo.Incident.Active, incident: :triage_vet_only}` in a
  policy's condition list, so the policy applies only during that incident.
  The check reads the switch on every evaluation; nothing is cached.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "the #{inspect(opts[:incident])} incident is switched on"

  @impl true
  def match?(_actor, _context, opts), do: ClinicDemo.Incident.active?(opts[:incident])
end
