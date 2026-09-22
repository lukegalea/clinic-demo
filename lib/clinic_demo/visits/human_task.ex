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

  relationships do
    # Candidacy rows are materialised when the task is created. The worklist
    # surfaces filter through them — "what may *this* clinician act on?".
    has_many :candidates, ClinicDemo.Visits.TaskCandidate do
      destination_attribute :task_id
      public? true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end
  end
end
