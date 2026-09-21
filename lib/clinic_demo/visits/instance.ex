defmodule ClinicDemo.Visits.Instance do
  @moduledoc "One run of the visit process, about one appointment."

  use AshBpmn.Resources.Instance,
    domain: ClinicDemo.Visits,
    repo: ClinicDemo.Repo,
    definition: ClinicDemo.Visits.Definition,
    table: "bpmn_instances"

  policies do
    policy action_type(:read) do
      authorize_if always()
    end
  end
end
