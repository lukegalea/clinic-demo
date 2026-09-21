defmodule ClinicDemo.Visits.Definition do
  @moduledoc """
  A versioned BPMN document. Publishing is one-way; an instance pins the version
  it started on for life.
  """

  use AshBpmn.Resources.Definition,
    domain: ClinicDemo.Visits,
    repo: ClinicDemo.Repo,
    table: "bpmn_definitions"

  policies do
    policy action_type(:read) do
      description "The process is readable by anything that can reach the application."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only a signed-in member of staff may draw or publish a process."
      authorize_if actor_present()
    end
  end
end
