defmodule ClinicDemo.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The audit surface (/events and the a2ui audit tables) reads the event
    # log's `action` column through `to_existing_atom` — an atom that only
    # exists once the wrapped resource's beam is loaded (the judgment
    # record's `:revise`/`:materialise` are the ones no other boot path
    # touches). Same for the value projection's `region` (`:clinic` lives
    # in the declarations' beam). A seeded log carries those rows from row
    # one, so the atom-carrier modules load before any surface can read.
    Enum.each(atom_carrier_modules(), &Code.ensure_loaded/1)

    children =
      [
        ClinicDemoWeb.Telemetry,
        ClinicDemo.Repo,
        {DNSCluster, query: Application.get_env(:clinic_demo, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ClinicDemo.PubSub},
        # Who-else-is-here for the a2ui surfaces (avatar stack in the
        # surface header). Rides the PubSub above; each host supervises its
        # own presence module per AshA2ui.Presence's wiring contract.
        ClinicDemoWeb.A2uiPresence
      ] ++
        value_drainer() ++
        [
          # Start to serve requests, typically the last entry
          ClinicDemoWeb.Endpoint
        ] ++ tidewave()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ClinicDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Modules whose beams carry the atoms stored in seeded database rows that
  # surfaces read through `to_existing_atom`:
  #
  #   * every resource wrapped with `AshEvents.Events` — the writers whose
  #     action names appear in the audit log's `action` column;
  #   * the value-ledger declarations — `:clinic` (the projection's region)
  #     and `:clinic_core` (the mapping source) are their literals;
  #   * the ledger's default event `resource`, `:"bizev.event"`, which only
  #     the package's StampEvent change carries (ash_discrete_business_events
  #     #12). The drainer reads the ledger before this VM has written to it.
  defp atom_carrier_modules do
    [
      ClinicDemo.Scheduling.Appointment,
      ClinicDemo.Scheduling.Clinician,
      ClinicDemo.Scheduling.Patient,
      ClinicDemo.Finance.Charge,
      ClinicDemo.Decisions.Evaluation,
      ClinicDemo.Judgments.Fact,
      ClinicDemo.Judgments.Observation,
      ClinicDemo.BusinessEvents.Declarations,
      AshDiscreteBusinessEvents.Ledger.Changes.StampEvent
    ]
  end

  # Folds new ledger events into the value projection as they land, so
  # /revenue follows the board live. Off in test, where the suite drains
  # explicitly inside its sandbox.
  defp value_drainer do
    if Application.get_env(:clinic_demo, :value_drainer, true),
      do: [ClinicDemo.BusinessEvents.ValueDrainer],
      else: []
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
