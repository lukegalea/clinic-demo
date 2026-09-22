defmodule ClinicDemo.Visits.Instance do
  @moduledoc "One run of the visit process, about one appointment."

  use AshBpmn.Resources.Instance,
    domain: ClinicDemo.Visits,
    repo: ClinicDemo.Repo,
    definition: ClinicDemo.Visits.Definition,
    table: "bpmn_instances"

  calculations do
    # The visit surfaces lead with these: where the instance stands and what
    # it is about, instead of two opaque ids.
    calculate :current_node, :string, ClinicDemo.Visits.Calculations.CurrentNode do
      public? true
    end

    calculate :subject_label, :string, ClinicDemo.Visits.Calculations.SubjectLabel do
      public? true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end
  end
end
