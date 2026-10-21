defmodule ClinicDemoWeb.Spike.HeexSurfaceLive do
  @moduledoc """
  SPIKE: the contract page's declared surface rendered on the server by
  `Atlas.A2uiHeex`, from the same A2UI messages the Lit catalog receives.
  Read-only. Compare with `/contracts/:id` (the Lit version).
  """

  use ClinicDemoWeb, :live_view

  import ClinicDemoWeb.Clm.Components

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    actor = socket.assigns[:a2ui_actor]
    ui = ClinicDemoWeb.A2ui.ContractUI

    {build_us, messages} =
      :timer.tc(fn ->
        context_state = AshA2ui.Info.context_state_for(ui, %{"contract" => id}, actor: actor)
        AshA2ui.Info.build_surface(ui, context_state: context_state, actor: actor)
      end)

    surface = Atlas.A2uiHeex.parse(messages)

    {:ok,
     assign(socket,
       id: id,
       surface: surface,
       stats: Atlas.A2uiHeex.stats(surface),
       build_ms: Float.round(build_us / 1000, 1),
       json_kb: Float.round(byte_size(JSON.encode!(messages)) / 1024, 1)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="font-sans text-(--atlas-text-primary) flex flex-col gap-6">
      <.workspace_bar />
      <section
        id="spike-notes"
        class="rounded-(--atlas-radius-xl) border border-(--atlas-border-pending) bg-(--atlas-bg-pending-subtle) p-4 text-sm flex flex-col gap-1"
      >
        <strong>Spike: the contract surface rendered by HEEx on the server, read-only.</strong>
        <span>
          {@stats.total} components: {@stats.rendered} rendered, {@stats.skipped} interactive skipped
          ({Enum.map_join(@stats.skipped_types, ", ", fn {type, n} -> "#{n} #{type}" end)}).
          Built in {@build_ms} ms; the same messages are {@json_kb} KB of JSON.
        </span>
        <.link navigate={~p"/contracts/#{@id}"} class="text-(--atlas-text-brand) underline">
          Compare with the Lit version
        </.link>
      </section>
      <Atlas.A2uiHeex.surface surface={@surface} />
    </div>
    """
  end
end
