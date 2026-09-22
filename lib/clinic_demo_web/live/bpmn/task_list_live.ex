defmodule ClinicDemoWeb.Bpmn.TaskListLive do
  @moduledoc """
  My tasks: the engine's own inbox, scoped to the acting clinician's
  principal id — exactly the candidacy the worklist surface enforces.
  """

  use AshBpmn.Web.TaskListLive,
    domain: ClinicDemo.Visits,
    principal_ids: {ClinicDemoWeb.Bpmn.Helpers, :current_principal_ids, []}
end
