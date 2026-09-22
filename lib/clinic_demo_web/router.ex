defmodule ClinicDemoWeb.Router do
  use ClinicDemoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ClinicDemoWeb.Layouts, :root}
    plug :protect_from_forgery
    # A2UI components inline their styles into shadow DOM; without
    # 'unsafe-inline' on style-src every surface renders unstyled. The
    # theme-switcher bootstrap is the one inline script — pinned by hash
    # rather than opening script-src up entirely.
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'sha256-BK52NP1e8rQFFVZCoDYB4YoCL0cZc/KAVl4dkMM7/QM='; img-src 'self' data:; font-src 'self' data:; connect-src 'self' ws: wss:"
    }

    # GET /a2ui/actor?id=<uuid> switches the acting Clinician (validated
    # against the configured actor list) and redirects back.
    plug AshA2ui.ActorPlug
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ClinicDemoWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/operator", PageController, :operator

    # The a2ui surfaces: one route per surface, all sharing the actor
    # session; every write runs under the acting Clinician.
    live_session :a2ui, on_mount: AshA2ui.Actor do
      live "/emergencies", A2ui.EmergencyBoardLive
      live "/schedule", A2ui.ScheduleLive
      live "/worklist", A2ui.WorklistLive
      live "/visits", A2ui.VisitsLive
      live "/patients", A2ui.PatientsLive
      live "/clinicians", A2ui.CliniciansLive
      live "/processes", A2ui.ProcessDefinitionsLive
      live "/decisions", A2ui.DecisionDefinitionsLive
      live "/evaluations", A2ui.EvaluationsLive
      live "/canvas", CanvasLive
      live "/agent", AgentLive
      live "/operator/tasks", Bpmn.TaskListLive
      live "/operator/processes/:key/designer", Bpmn.DesignerLive
      live "/operator/instances/:id", Bpmn.ViewerLive
      live "/operator/decisions/:key/editor", Decisions.EditorLive
    end
  end

  # The framework's actor picker, in its own scope so the app's aliasing
  # does not claim it.
  scope "/", AshA2ui do
    pipe_through :browser

    live "/acting-as", ActorPickerLive
  end

  # Clarity inlines its whole JS bundle into the page, which needs inline +
  # eval scripts — the app's strict CSP forbids both. It gets its own
  # pipeline and scope so the relaxation reaches /clarity alone, and the
  # scope exists only where the dev-only dep is present.
  pipeline :clarity_browser do
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; img-src 'self' data:; font-src 'self' data:; connect-src 'self' ws: wss:"
    }
  end

  import Clarity.Router

  # Clarity is a first-class operator tool here, not a dev extra: the routes
  # mount unconditionally so every env compiles the same router. The relaxed
  # CSP it needs stays scoped to this pipeline.
  scope "/clarity" do
    pipe_through [:browser, :clarity_browser]

    clarity("/")
  end

  # Other scopes may use custom stacks.
  # scope "/api", ClinicDemoWeb do
  #   pipe_through :api
  # end
end
