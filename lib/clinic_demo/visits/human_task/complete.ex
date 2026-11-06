defmodule ClinicDemo.Visits.HumanTask.Complete do
  @moduledoc """
  The run of every completion action on `ClinicDemo.Visits.HumanTask`: the
  general `:complete_task` and the worklist's one-per-step actions
  (`:complete_check_in`, `:complete_consult`, `:complete_lab_results`). They
  differ only in which outcomes their `:outcome` argument offers; each hands
  the task id, the outcome and the comment to `ClinicDemo.Visits.TaskDesk`
  as the acting clinician.
  """

  use Ash.Resource.Actions.Implementation

  alias ClinicDemo.Visits.TaskDesk

  @impl true
  def run(input, _opts, context) do
    TaskDesk.complete(
      input.arguments.record_id,
      input.arguments.outcome,
      Map.get(input.arguments, :comment),
      context.actor
    )
  end
end
