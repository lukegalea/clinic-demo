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
    # rather than opening script-src up entirely. The Google Fonts origins
    # serve DM Sans, the design system's typeface (linked in the root
    # layout).
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; script-src 'self' 'sha256-BK52NP1e8rQFFVZCoDYB4YoCL0cZc/KAVl4dkMM7/QM='; img-src 'self' data:; font-src 'self' data: https://fonts.gstatic.com; connect-src 'self' ws: wss:"
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  import Phoenix.LiveDashboard.Router

  scope "/", ClinicDemoWeb do
    pipe_through :browser

    get "/home", PageController, :home
    get "/operator", PageController, :operator

    # The operator's system window: request timings, process tree, VM
    # metrics, channel traffic — everything the Telemetry module already
    # emits, made visible. Linked from the operator hub's Infrastructure
    # section; a dev-served demo, so no prod gating.
    live_dashboard "/dev/dashboard", metrics: ClinicDemoWeb.Telemetry

    # The a2ui surfaces: one route per surface, all sharing the actor
    # session; every write runs under the acting Clinician.
    # The board is the main UI: the process as lanes, one card column per
    # stage. Intake takes a new patient; the schedule books the visit.
    live_session :a2ui, on_mount: AshA2ui.Actor do
      live "/", A2ui.BoardLive
      live "/intake", A2ui.IntakeLive
      live "/emergencies", A2ui.EmergencyBoardLive
      live "/schedule", A2ui.ScheduleLive
      live "/worklist", A2ui.WorklistLive
      live "/visits", A2ui.VisitsLive
      live "/patients", A2ui.PatientsLive
      live "/clinicians", A2ui.CliniciansLive
      live "/processes", A2ui.ProcessDefinitionsLive
      live "/decisions", A2ui.DecisionDefinitionsLive
      live "/evaluations", A2ui.EvaluationsLive
      live "/events", A2ui.EventsLive
      live "/canvas", CanvasLive
      live "/agent", AgentLive
      live "/operator/tasks", Bpmn.TaskListLive
      live "/operator/processes/:key/designer", Bpmn.DesignerLive
      live "/operator/instances/:id", Bpmn.ViewerLive
      live "/operator/decisions/:key/editor", Decisions.EditorLive
      live "/operator/rules", Compliance.RulesetEditorLive

      # The actor picker, mounted in the surfaces' live_session — the
      # pattern ash_a2ui's ActorPickerLive documents as preferred: the
      # Actor on_mount is already running here, and reaching the picker is
      # live navigation (no document reload). The actor SWITCH itself
      # remains a full redirect by design — ActorPlug writes the session
      # over HTTP and 302s back. `alias: false` keeps the app's scope from
      # prefixing the framework module.
      scope "/", alias: false do
        live "/acting-as", AshA2ui.ActorPickerLive
      end
    end
  end

  # Clarity inlines its whole JS bundle into the page, which needs inline +
  # eval scripts — the app's strict CSP forbids both. It gets its own
  # pipeline and scope so the relaxation reaches /clarity alone, and the
  # scope exists only where the dev-only dep is present.
  pipeline :clarity_browser do
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; script-src 'self' 'unsafe-inline' 'unsafe-eval'; img-src 'self' data:; font-src 'self' data: https://fonts.gstatic.com; connect-src 'self' ws: wss:"
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

  # Component storybook (dev-only). `Mix.env()` rather than the dev_routes
  # flag: phoenix_storybook is `only: :dev`, so in test/prod the module
  # doesn't exist in the code path at all — Application.compile_env cannot
  # eliminate the branch before the import is resolved, but Mix.env() is a
  # compile-time constant the dead-code eliminator acts on.
  if Mix.env() == :dev do
    import PhoenixStorybook.Router

    scope "/" do
      storybook_assets()
    end

    scope "/", ClinicDemoWeb do
      pipe_through [:browser, :clarity_browser]

      live_storybook("/storybook",
        backend_module: ClinicDemoWeb.Storybook,
        title: "ClinicDemo Storybook"
      )
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", ClinicDemoWeb do
  #   pipe_through :api
  # end
end
