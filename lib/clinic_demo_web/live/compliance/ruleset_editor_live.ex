defmodule ClinicDemoWeb.Compliance.RulesetEditorLive do
  @moduledoc """
  The operator-facing rule authoring surface: ash_compliance's structured
  ruleset editor mounted over the clinic's one fixed organization.

  Everything the editor can do — draft revisions, validate, approve,
  activate, compile and activate the policy bundle — is the package's own
  lifecycle wired to `AshCompliance.Domain`; this module only supplies the
  host wiring:

    * the organization is the demo's fixed org
      (`ClinicDemo.Compliance.organization_id/1`, called with the socket per
      the editor's MFA contract);
    * the actor is whoever is acting through the a2ui actor picker
      (`socket.assigns[:a2ui_actor]` — the same actor every other operator
      surface runs as, `nil` when nobody is acting). The editor calls with
      `authorize?: true`; the compliance resources declare no policies, so
      the actor is attribution, not a gate.
  """

  use AshCompliance.Web.RulesetEditorLive,
    domain: AshCompliance.Domain,
    organization: {ClinicDemo.Compliance, :organization_id, []},
    actor: {__MODULE__, :actor, []}

  @doc "The a2ui actor, shared with every other operator surface."
  def actor(socket), do: socket.assigns[:a2ui_actor]
end
