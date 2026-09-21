defmodule ClinicDemo.Visits.ProcessEvent do
  @moduledoc """
  The audit trail: every node entered, every decision evaluated, every task
  claimed and completed, in order.
  """

  use AshBpmn.Resources.ProcessEvent,
    domain: ClinicDemo.Visits,
    repo: ClinicDemo.Repo,
    instance: ClinicDemo.Visits.Instance,
    table: "bpmn_process_events"

  policies do
    policy action_type(:read) do
      description "The trail is readable; that is the reason it is kept."
      authorize_if always()
    end
  end
end
