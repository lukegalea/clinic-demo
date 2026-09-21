defmodule ClinicDemo.Visits.TaskCandidate do
  @moduledoc """
  Who may take a task, materialised as rows when the task is created, so the
  task list is one indexed query rather than a policy evaluated per row.
  """

  use AshBpmn.Resources.TaskCandidate,
    domain: ClinicDemo.Visits,
    repo: ClinicDemo.Repo,
    task: ClinicDemo.Visits.HumanTask,
    table: "bpmn_task_candidates"

  policies do
    policy action_type(:read) do
      authorize_if always()
    end
  end
end
