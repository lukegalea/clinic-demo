defmodule ClinicDemo.Visits.HumanTask do
  @moduledoc """
  A work item waiting on a person: the front desk checking an animal in, the vet
  seeing it, the lab reporting back. Each one is a token that has stopped.
  """

  use AshBpmn.Resources.HumanTask,
    domain: ClinicDemo.Visits,
    repo: ClinicDemo.Repo,
    instance: ClinicDemo.Visits.Instance,
    token: ClinicDemo.Visits.Token,
    table: "bpmn_human_tasks"

  policies do
    policy action_type(:read) do
      authorize_if always()
    end
  end
end
