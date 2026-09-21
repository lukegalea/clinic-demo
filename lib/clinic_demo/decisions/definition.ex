defmodule ClinicDemo.Decisions.Definition do
  @moduledoc """
  A versioned DMN document.

  Everything about this resource — attributes, the lifecycle actions, the
  at-most-one-draft-per-key index — comes from `AshDecisions.Resources.Definition`.
  The demo supplies a repo and a policy set and nothing else.
  """

  use AshDecisions.Resources.Definition,
    domain: ClinicDemo.Decisions,
    repo: ClinicDemo.Repo,
    table: "dmn_definitions"

  policies do
    policy action_type(:read) do
      description "Rules are readable by anything that can reach the application."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only a signed-in member of staff may author or publish a rule."
      authorize_if actor_present()
    end
  end
end
