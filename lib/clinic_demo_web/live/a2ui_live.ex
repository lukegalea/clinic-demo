# One mount module per surface — the whole LiveView is the LiveRenderer use,
# pointed at a standalone UI module and the actor the session hook assigns.
defmodule ClinicDemoWeb.A2ui.ScheduleLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.AppointmentUI,
    actor_fn: & &1.assigns.a2ui_actor
end

defmodule ClinicDemoWeb.A2ui.WorklistLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.WorklistUI,
    actor_fn: & &1.assigns.a2ui_actor
end

defmodule ClinicDemoWeb.A2ui.VisitsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.VisitInstanceUI,
    actor_fn: & &1.assigns.a2ui_actor
end

defmodule ClinicDemoWeb.A2ui.PatientsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.PatientUI,
    actor_fn: & &1.assigns.a2ui_actor
end

defmodule ClinicDemoWeb.A2ui.CliniciansLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.ClinicianUI,
    actor_fn: & &1.assigns.a2ui_actor
end

defmodule ClinicDemoWeb.A2ui.ProcessDefinitionsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.ProcessDefinitionUI,
    actor_fn: & &1.assigns.a2ui_actor
end

defmodule ClinicDemoWeb.A2ui.DecisionDefinitionsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.DecisionDefinitionUI,
    actor_fn: & &1.assigns.a2ui_actor
end

defmodule ClinicDemoWeb.A2ui.EvaluationsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.EvaluationUI,
    actor_fn: & &1.assigns.a2ui_actor
end
