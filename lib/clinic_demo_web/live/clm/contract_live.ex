defmodule ClinicDemoWeb.Clm.ContractLive do
  @moduledoc """
  CLM 2.0 POC: the contract page. A HEEx shell around the declared
  `ClinicDemoWeb.A2ui.ContractUI` surface.

  The shell draws what the A2UI vocabulary cannot say yet: the header (title,
  status tags, parties line), the "check what the AI extracted" notice, the
  lifecycle bar and the sticky footer. The route's `:id` is the contract: it
  is handed to the surface as its `:contract` context (through the same
  authorized read a selection takes) and loaded here for the shell, which
  reloads it after every surface action and every extracted-value change, so
  the footer's count follows the To check table.

  Strings are English only: the Atlas Bilingual page has no French pairs for
  them, and none are invented.
  """

  use AshA2ui.LiveRenderer,
    ui: ClinicDemoWeb.A2ui.ContractUI,
    actor_fn: & &1.assigns.a2ui_actor,
    pubsub: [module: ClinicDemo.PubSub, topics: ["clm_extracted_values:updated"]]

  use Phoenix.VerifiedRoutes,
    endpoint: ClinicDemoWeb.Endpoint,
    router: ClinicDemoWeb.Router,
    statics: ClinicDemoWeb.static_paths()

  import ClinicDemoWeb.Clm.Components

  @contract_loads [
    :to_check_count,
    :verified?,
    :notice_deadline,
    :expiring_soon_on,
    :total_value_text,
    :annual_value_text,
    :property_count,
    :service_count,
    documents: [:filename]
  ]

  @impl true
  def mount(%{"id" => id} = params, session, socket) do
    # The surface reads its contexts from `ctx`; the page's contract is the path's.
    params = Map.put(params, "ctx", %{"contract" => id})
    {:ok, socket} = AshA2ui.LiveRenderer.mount(__ash_a2ui_config__(), params, session, socket)
    {:ok, assign(socket, contract: load_contract(id, socket), today: Date.utc_today())}
  end

  @impl true
  def handle_event("a2ui:action", envelope, socket) do
    {:noreply, socket} =
      AshA2ui.LiveRenderer.handle_action(__ash_a2ui_config__(), envelope, socket)

    {:noreply, reload_contract(socket)}
  end

  def handle_event(event, params, socket), do: super(event, params, socket)

  @impl true
  def handle_info(message, socket) do
    {:noreply, socket} =
      AshA2ui.LiveRenderer.handle_notification(__ash_a2ui_config__(), message, socket)

    {:noreply, reload_contract(socket)}
  end

  defp reload_contract(%{assigns: %{contract: nil}} = socket), do: socket

  defp reload_contract(socket),
    do: assign(socket, :contract, load_contract(socket.assigns.contract.id, socket))

  defp load_contract(nil, _socket), do: nil

  defp load_contract(id, socket) do
    case ClinicDemo.Clm.get_contract(id,
           load: @contract_loads,
           actor: socket.assigns[:a2ui_actor]
         ) do
      {:ok, contract} -> contract
      {:error, _} -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="font-sans text-(--atlas-text-primary) flex flex-col gap-6 pb-24">
      <.workspace_bar />
      <nav aria-label="Breadcrumb" class="text-sm">
        <.link navigate={~p"/contracts"} class="text-(--atlas-text-brand) hover:underline">
          Contracts
        </.link>
        <span :if={@contract} class="text-(--atlas-text-secondary)">
          <span aria-hidden="true" class="mx-1">›</span>{@contract.name}
        </span>
      </nav>

      <.contract_header :if={@contract} contract={@contract} today={@today} />
      <p :if={!@contract} id="clm-contract-missing" class="text-(--atlas-text-secondary)">
        This contract doesn't exist, or you can't see it.
      </p>

      <%!-- The shell owns the page heading: the surface leaves its title out. --%>
      <div data-atlas-shell-title>
        <Atlas.Surface.container rows={4} filters={false} />
      </div>

      <footer
        :if={@contract}
        id="clm-review-footer"
        class="fixed bottom-0 right-0 left-0 md:left-56 z-10 border-t border-(--atlas-border-default) bg-(--atlas-bg-surface)"
      >
        <div class="px-4 md:px-6 h-16 flex items-center gap-3 text-sm">
          <%= if @contract.verified? do %>
            <Atlas.Components.tag color="green" size="sm">Verified</Atlas.Components.tag>
            <span class="text-(--atlas-text-secondary)">Every extracted detail has been checked.</span>
          <% else %>
            <span class="font-medium">Reviewing extracted details</span>
            <span
              id="clm-to-check-count"
              class="inline-flex items-center gap-1.5 text-(--atlas-text-warning)"
            >
              <span aria-hidden="true" class="size-2 rounded-full bg-(--atlas-bg-warning)"></span>
              {@contract.to_check_count} to check
            </span>
          <% end %>
        </div>
      </footer>
    </div>
    """
  end

  attr :contract, :map, required: true
  attr :today, Date, required: true

  defp contract_header(assigns) do
    ~H"""
    <header class="flex flex-col gap-3">
      <h1 class="text-2xl font-semibold">{@contract.name}</h1>
      <div class="flex flex-wrap items-center gap-2 text-sm text-(--atlas-text-secondary)">
        <%= if @contract.verified? do %>
          <Atlas.Components.tag color="green" size="sm">Verified</Atlas.Components.tag>
        <% else %>
          <Atlas.Components.tag color="gold" size="sm">Unverified</Atlas.Components.tag>
        <% end %>
        <Atlas.Components.tag
          :if={stage(@contract, @today) == :expiring_soon}
          color="orange"
          size="sm"
        >
          Expiring soon
        </Atlas.Components.tag>
        <Atlas.Components.tag :if={stage(@contract, @today) == :expired} color="red" size="sm">
          Expired
        </Atlas.Components.tag>
        <span>
          {@contract.vendor_name} · {plural(@contract.property_count, "property", "properties")} · {plural(
            @contract.service_count,
            "service",
            "services"
          )}
        </span>
      </div>
    </header>

    <section
      :if={not @contract.verified?}
      id="clm-ai-notice"
      class="rounded-(--atlas-radius-xl) border border-(--atlas-border-warning) bg-(--atlas-bg-warning-subtle) p-4 flex flex-col gap-1"
    >
      <h2 class="font-semibold">Check what the AI extracted</h2>
      <p class="text-sm text-(--atlas-text-secondary)">
        The AI read these details from {source_file(@contract)}. {@contract.to_check_count} haven't been checked by a person yet: confirm or correct each one in the To check table below.
      </p>
    </section>

    <section
      id="clm-lifecycle"
      aria-label="Lifecycle"
      class="rounded-(--atlas-radius-xl) border border-(--atlas-border-default) bg-(--atlas-bg-surface) grid grid-cols-1 md:grid-cols-[1fr_auto]"
    >
      <ol class="p-4 grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-4">
        <li :for={step <- lifecycle(@contract, @today)} class="flex flex-col gap-0.5 min-w-0">
          <span class="flex items-center gap-2">
            <span
              aria-hidden="true"
              class={[
                "size-3 rounded-full border-2 shrink-0",
                step.state == :done && "bg-(--atlas-bg-brand) border-(--atlas-border-brand)",
                step.state == :current && "bg-(--atlas-bg-warning) border-(--atlas-border-warning)",
                step.state == :next && "border-(--atlas-border-warning)",
                step.state == :later && "border-(--atlas-border-strong)"
              ]}
            ></span>
            <span class="text-sm text-(--atlas-text-secondary)">{step.label}</span>
          </span>
          <span class={["font-semibold", step.urgent? && "text-(--atlas-text-danger)"]}>
            {format_date(step.date)}
          </span>
          <span
            :if={step.note}
            class={[
              "text-xs",
              step.urgent? && "text-(--atlas-text-danger)",
              !step.urgent? && "text-(--atlas-text-tertiary)"
            ]}
          >
            {step.note}
          </span>
        </li>
      </ol>
      <div class="p-4 border-t md:border-t-0 md:border-l border-(--atlas-border-default) flex flex-col gap-0.5">
        <span class="text-sm text-(--atlas-text-secondary)">Total value</span>
        <span class="text-xl font-semibold">{@contract.total_value_text || "—"}</span>
        <span :if={@contract.annual_value_text} class="text-xs text-(--atlas-text-tertiary)">
          {@contract.annual_value_text} a year
        </span>
      </div>
    </section>
    """
  end

  defp stage(contract, today) do
    cond do
      Date.compare(today, contract.expires_on) == :gt -> :expired
      Date.compare(today, contract.expiring_soon_on) != :lt -> :expiring_soon
      true -> :active
    end
  end

  # Started → Expiring soon → Notice deadline → Expires (→ Auto-extends).
  defp lifecycle(contract, today) do
    steps =
      [
        {"Started", contract.starts_on, nil},
        {"Expiring soon", contract.expiring_soon_on, nil},
        {"Notice deadline", contract.notice_deadline, :countdown},
        {"Expires", contract.expires_on, :countdown}
      ] ++
        if(contract.renewal_mode == :auto_extend,
          do: [{"Auto-extends", contract.expires_on, "Extends on current terms"}],
          else: []
        )

    steps = Enum.reject(steps, fn {_, date, _} -> is_nil(date) end)
    next = Enum.find_index(steps, fn {_, date, _} -> Date.compare(date, today) == :gt end)

    steps
    |> Enum.with_index()
    |> Enum.map(fn {{label, date, note}, i} ->
      days = Date.diff(date, today)

      %{
        label: label,
        date: date,
        state:
          cond do
            is_nil(next) or i < next - 1 -> :done
            i == next - 1 -> :current
            i == next -> :next
            true -> :later
          end,
        urgent?: note == :countdown and days in 0..90,
        note:
          case note do
            :countdown when days > 0 -> "In #{plural(days, "day", "days")}"
            :countdown when days == 0 -> "Today"
            :countdown -> nil
            text -> text
          end
      }
    end)
  end

  defp source_file(%{documents: [%{filename: filename} | _]}), do: filename
  defp source_file(_contract), do: "the signed document"

  defp plural(1, one, _many), do: "1 #{one}"
  defp plural(n, _one, many), do: "#{n} #{many}"

  defp format_date(nil), do: "—"
  defp format_date(date), do: Calendar.strftime(date, "%b %-d, %Y")
end
