defmodule Atlas.Surface do
  @moduledoc """
  The A2UI surface container, with a server-rendered placeholder.

  ash_a2ui's own skeleton is drawn by the client hook in `mounted()`, after
  the bundle has run and the LiveView socket has joined, and is removed when
  the surface is created. Measured in the POC (`/contracts`): the page paints
  at ~70 ms, the hook's skeleton lives from ~300 ms for ~7 ms, the content
  lands at ~360–430 ms. So the screen area was blank for ~300 ms and the
  skeleton was never seen.

  This placeholder is in the server HTML, so it paints with the page, and is
  removed by `assets/js/atlas/placeholder.js` once the surface has actually
  rendered. While it is there, the hook's own skeleton is hidden (app.css),
  so the two never flash over each other.

  Same markup contract as `AshA2ui.LiveRenderer.surface_container/1` (one
  container, hook, `phx-update="ignore"`): until upstream takes a placeholder
  slot, this is the one place that repeats it.
  """

  use Phoenix.Component

  attr :rows, :integer, default: 6, doc: "placeholder table rows"
  attr :filters, :boolean, default: true, doc: "show a filter-bar placeholder"

  def container(assigns) do
    ~H"""
    <div id="ash-a2ui-surface" phx-hook="AshA2ui" phx-update="ignore">
      <div
        data-atlas-placeholder
        role="status"
        aria-busy="true"
        aria-label="Loading"
        class="flex flex-col gap-4 animate-pulse motion-reduce:animate-none"
      >
        <div
          :if={@filters}
          class="h-16 rounded-(--atlas-radius-xl) border border-(--atlas-border-default) bg-(--atlas-bg-surface)"
        >
        </div>
        <div class="rounded-(--atlas-radius-xl) border border-(--atlas-border-default) bg-(--atlas-bg-surface) overflow-hidden">
          <div class="h-10 bg-(--atlas-bg-surface-sunken)"></div>
          <div
            :for={row <- 1..@rows}
            class="h-12 px-4 flex items-center gap-6 border-t border-(--atlas-border-default)"
          >
            <div class={[
              "h-3 rounded-(--atlas-radius-default) bg-(--atlas-bg-surface-sunken)",
              if(rem(row, 2) == 0, do: "w-1/4", else: "w-1/3")
            ]}>
            </div>
            <div class="h-3 w-1/6 rounded-(--atlas-radius-default) bg-(--atlas-bg-surface-sunken)">
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
