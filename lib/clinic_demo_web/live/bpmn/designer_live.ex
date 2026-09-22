defmodule ClinicDemoWeb.Bpmn.DesignerLive do
  @moduledoc """
  Draw and publish a visit process. The route carries the process key; the
  acting clinician is the author of record.
  """

  use AshBpmn.Web.DesignerLive,
    domain: ClinicDemo.Visits,
    actor: {ClinicDemoWeb.Bpmn.Helpers, :current_actor, []}
end
