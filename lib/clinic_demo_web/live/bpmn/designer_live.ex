defmodule ClinicDemoWeb.Bpmn.DesignerLive do
  @moduledoc """
  Draw and publish a visit process. The route carries the process key; the
  acting clinician is the author of record.

  The catalogues turn the properties panel's binding fields into
  comboboxes: the action ref suggests the visit process's invoker
  vocabulary (one FEEL row per the action's declared arguments), and the
  decision ref suggests the DMN keys with their publish status. See
  `ClinicDemoWeb.Bpmn.Helpers`.
  """

  use AshBpmn.Web.DesignerLive,
    domain: ClinicDemo.Visits,
    actor: {ClinicDemoWeb.Bpmn.Helpers, :current_actor, []},
    actions: {ClinicDemoWeb.Bpmn.Helpers, :action_catalogue, []},
    decisions: {ClinicDemoWeb.Bpmn.Helpers, :decision_catalogue, []}
end
