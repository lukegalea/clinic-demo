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
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ClinicDemoWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", ClinicDemoWeb do
  #   pipe_through :api
  # end
end
