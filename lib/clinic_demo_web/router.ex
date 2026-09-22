defmodule ClinicDemoWeb.Router do
  use ClinicDemoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ClinicDemoWeb.Layouts, :root}
    plug :protect_from_forgery
    # A2UI components inline their styles into shadow DOM; without
    # 'unsafe-inline' on style-src every surface renders unstyled.
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; img-src 'self' data:; connect-src 'self' ws: wss:"
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

    # The a2ui surfaces: one route per surface, all sharing the actor
    # session; every write runs under the acting Clinician.
    live_session :a2ui, on_mount: AshA2ui.Actor do
      live "/schedule", A2ui.ScheduleLive
      live "/worklist", A2ui.WorklistLive
      live "/visits", A2ui.VisitsLive
      live "/patients", A2ui.PatientsLive
      live "/clinicians", A2ui.CliniciansLive
      live "/processes", A2ui.ProcessDefinitionsLive
      live "/decisions", A2ui.DecisionDefinitionsLive
      live "/evaluations", A2ui.EvaluationsLive
    end
  end

  # The framework's actor picker, in its own scope so the app's aliasing
  # does not claim it.
  scope "/", AshA2ui do
    pipe_through :browser

    live "/acting-as", ActorPickerLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", ClinicDemoWeb do
  #   pipe_through :api
  # end
end
