defmodule ClinicDemo.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ClinicDemoWeb.Telemetry,
        ClinicDemo.Repo,
        {DNSCluster, query: Application.get_env(:clinic_demo, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ClinicDemo.PubSub},
        # Who-else-is-here for the a2ui surfaces (avatar stack in the
        # surface header). Rides the PubSub above; each host supervises its
        # own presence module per AshA2ui.Presence's wiring contract.
        ClinicDemoWeb.A2uiPresence,
        # Start a worker by calling: ClinicDemo.Worker.start_link(arg)
        # {ClinicDemo.Worker, arg},
        # Start to serve requests, typically the last entry
        ClinicDemoWeb.Endpoint
      ] ++ tidewave()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ClinicDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The MCP supervisor behind the endpoint's Tidewave plug — it owns the ETS
  # tables and log handlers the /tidewave/mcp handler uses. Dev only: in
  # every other env the plug never mounts and this stays unstarted.
  defp tidewave do
    if Application.get_env(:clinic_demo, :tidewave?, false), do: [{Tidewave.MCP, []}], else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ClinicDemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
