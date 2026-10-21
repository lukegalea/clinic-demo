defmodule ClinicDemoWeb.Clm.ContractsHubLive do
  @moduledoc """
  CLM 2.0 POC: the Contracts Hub. A HEEx shell around the declared
  `ClinicDemoWeb.A2ui.ContractsHubUI` surface.

  The shell draws the workspace bar, the title and the four stat cards. Each
  card is a link that reopens the hub with the table's filter set in the URL
  (`?q[filters][status]=expiring_soon`), which the surface validates against
  its declared query like any other client input: the cards are navigation,
  not a second filter implementation.
  """

  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.ContractsHubUI,
    actor_fn: & &1.assigns.a2ui_actor,
    open_surface: &ClinicDemoWeb.A2ui.Links.open/2

  use Phoenix.VerifiedRoutes,
    endpoint: ClinicDemoWeb.Endpoint,
    router: ClinicDemoWeb.Router,
    statics: ClinicDemoWeb.static_paths()

  import ClinicDemoWeb.Clm.Components

  @impl true
  def mount(params, session, socket) do
    {:ok, socket} = AshA2ui.LiveRenderer.mount(__ash_a2ui_config__(), params, session, socket)
    {:ok, assign(socket, stats: stats(socket))}
  end

  defp stats(socket) do
    contracts =
      ClinicDemo.Clm.list_contracts!(
        load: [:status, :verified?, :notice_deadline],
        actor: socket.assigns[:a2ui_actor]
      )

    by_status = Enum.group_by(contracts, & &1.status)
    expiring = Map.get(by_status, :expiring_soon, [])

    %{
      expiring_soon: length(expiring),
      next_deadline:
        expiring
        |> Enum.map(& &1.notice_deadline)
        |> Enum.filter(&(&1 && Date.compare(&1, Date.utc_today()) != :lt))
        |> Enum.min(Date, fn -> nil end),
      unverified: Enum.count(contracts, &(not &1.verified?)),
      total: length(contracts),
      active: length(Map.get(by_status, :active, [])),
      expired: length(Map.get(by_status, :expired, []))
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="font-sans text-(--atlas-text-primary) flex flex-col gap-6">
      <.workspace_bar active={:all} />
      <h1 class="text-2xl font-semibold">Contracts</h1>

      <div id="clm-stats" class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <.stat_card
          id="clm-stat-expiring"
          dot="bg-(--atlas-bg-warning)"
          label="Expiring soon"
          value={@stats.expiring_soon}
          value_class="text-(--atlas-text-warning)"
          href={~p"/contracts?#{[q: [filters: [status: "expiring_soon"]]]}"}
        >
          <span :if={@stats.next_deadline}>
            Next notice deadline {Calendar.strftime(@stats.next_deadline, "%b %-d")}
          </span>
        </.stat_card>
        <.stat_card
          id="clm-stat-unverified"
          dot="bg-(--atlas-bg-pending)"
          label="Unverified"
          value={@stats.unverified}
          value_class="text-(--atlas-text-pending)"
          href={~p"/contracts?#{[q: [filters: [verified?: "false"]]]}"}
        >
          <div
            class="h-1.5 rounded-full bg-(--atlas-bg-surface-sunken) overflow-hidden"
            role="img"
            aria-label={"#{@stats.total - @stats.unverified} of #{@stats.total} verified"}
          >
            <div
              class="h-full bg-(--atlas-bg-success)"
              style={"width: #{verified_percent(@stats)}%"}
            >
            </div>
          </div>
        </.stat_card>
        <.stat_card
          id="clm-stat-active"
          dot="bg-(--atlas-bg-brand)"
          label="Active"
          value={@stats.active}
          href={~p"/contracts?#{[q: [filters: [status: "active"]]]}"}
        >
          Signed and in force
        </.stat_card>
        <.stat_card
          id="clm-stat-expired"
          dot="bg-(--atlas-bg-neutral)"
          label="Expired"
          value={@stats.expired}
          href={~p"/contracts?#{[q: [filters: [status: "expired"]]]}"}
        >
          Past their expiry date
        </.stat_card>
      </div>

      <%!-- The shell owns the page heading: the surface leaves its title out. --%>
      <div data-atlas-shell-title>
        <Atlas.Surface.container rows={8} filters={true} />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :dot, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :value_class, :string, default: nil
  attr :href, :string, required: true
  slot :inner_block

  defp stat_card(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@href}
      class="group flex flex-col gap-1 p-4 rounded-(--atlas-radius-xl) border border-(--atlas-border-default) bg-(--atlas-bg-surface) hover:border-(--atlas-border-strong) focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-(--atlas-border-focus)"
    >
      <span class="flex items-center gap-2 text-sm text-(--atlas-text-secondary)">
        <span aria-hidden="true" class={["size-2 rounded-full", @dot]}></span>
        {@label}
      </span>
      <span class={["text-3xl font-semibold", @value_class]}>{@value}</span>
      <span class="text-sm text-(--atlas-text-secondary)">{render_slot(@inner_block)}</span>
      <span class="mt-auto pt-2 text-sm text-(--atlas-text-brand) group-hover:underline">
        View all
      </span>
    </.link>
    """
  end

  defp verified_percent(%{total: 0}), do: 0

  defp verified_percent(%{total: total, unverified: unverified}),
    do: round((total - unverified) * 100 / total)
end
