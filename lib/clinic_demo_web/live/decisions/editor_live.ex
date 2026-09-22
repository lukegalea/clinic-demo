defmodule ClinicDemoWeb.Decisions.EditorLive do
  @moduledoc """
  Edit and publish a decision table — the rule a head vet changes on a
  Tuesday afternoon, without a deploy. The route carries the decision key.
  """

  use AshDecisions.Web.EditorLive,
    domain: ClinicDemo.Decisions,
    actor: {ClinicDemoWeb.Bpmn.Helpers, :current_actor, []}
end
