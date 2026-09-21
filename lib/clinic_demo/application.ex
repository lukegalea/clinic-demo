defmodule ClinicDemo.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ClinicDemoWeb.Telemetry,
      ClinicDemo.Repo,
      {DNSCluster, query: Application.get_env(:clinic_demo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ClinicDemo.PubSub},
      # Start a worker by calling: ClinicDemo.Worker.start_link(arg)
      # {ClinicDemo.Worker, arg},
      # Start to serve requests, typically the last entry
      ClinicDemoWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ClinicDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ClinicDemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
