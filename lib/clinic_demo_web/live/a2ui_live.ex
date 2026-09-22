# One mount module per surface — the whole LiveView is the LiveRenderer use,
# pointed at a standalone UI module and the actor the session hook assigns.
defmodule ClinicDemoWeb.A2ui.BoardLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.BoardUI,
    actor_fn: & &1.assigns.a2ui_actor
end

defmodule ClinicDemoWeb.A2ui.IntakeLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.IntakeUI,
    actor_fn: & &1.assigns.a2ui_actor
end

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

  # The surface shows where each visit stands; the engine's own task inbox
  # is the view that carries the per-instance context — the BPMN viewer's
  # live token overlay renders from there.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
      <div class="flex flex-wrap gap-2">
        <a
          href="/operator/tasks"
          class="inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-secondary-background px-3 text-sm font-base text-foreground shadow-shadow ring-offset-white transition-all hover:translate-x-boxShadowX hover:translate-y-boxShadowY hover:shadow-none"
        >
          Open instances in the process viewer (via tasks)
        </a>
      </div>
    </div>
    """
  end
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

  # The surface shows the what; these links give the where-to-go. The
  # published version is read-only by construction — the designer is where
  # the next version gets drawn.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
      <div class="flex flex-wrap gap-2">
        <a
          href="/operator/processes/appointment_visit/designer"
          class="inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-secondary-background px-3 text-sm font-base text-foreground shadow-shadow ring-offset-white transition-all hover:translate-x-boxShadowX hover:translate-y-boxShadowY hover:shadow-none"
        >
          Draw appointment_visit in the designer
        </a>
      </div>
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.DecisionDefinitionsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.DecisionDefinitionUI,
    actor_fn: & &1.assigns.a2ui_actor

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <AshA2ui.LiveRenderer.surface_container />
      <div class="flex flex-wrap gap-2">
        <a
          href="/operator/decisions/appointment.triage/editor"
          class="inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-secondary-background px-3 text-sm font-base text-foreground shadow-shadow ring-offset-white transition-all hover:translate-x-boxShadowX hover:translate-y-boxShadowY hover:shadow-none"
        >
          Edit appointment.triage in the DMN editor
        </a>
      </div>
    </div>
    """
  end
end

defmodule ClinicDemoWeb.A2ui.EmergencyBoardLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.EmergencyBoardUI,
    actor_fn: & &1.assigns.a2ui_actor
end

defmodule ClinicDemoWeb.A2ui.EvaluationsLive do
  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.EvaluationUI,
    actor_fn: & &1.assigns.a2ui_actor
end
