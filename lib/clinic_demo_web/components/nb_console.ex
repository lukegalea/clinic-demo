defmodule ClinicDemoWeb.Components.NbConsole do
  @moduledoc """
  Neobrutalist console chrome: transcript messages and their scroller.

  Two pieces, both dumb:

    * `<.nb_message>` — one transcript entry: a sticker-style card whose
      severity rides the shared badge tone palette (same fills as
      `CoreComponents.badge/1`, same `shadow-shadow`/`border-2` vocabulary
      as every other neobrutalist block here).
    * `<.nb_message_scroller>` — the stream-backed scroll region around
      them: `phx-update="stream"` per the zero-jank rules (§2 — keyed
      children, never a re-rendered list assign), with the tiny `NbScroller`
      hook pinning the view to the newest message unless the person has
      scrolled up to read history.

  Neither component knows anything about the agent; the console owns when
  messages enter the stream.
  """

  use Phoenix.Component

  attr :id, :string, required: true
  attr :stream, :list, required: true, doc: "a `stream/3` handle from the LiveView"

  attr :rest, :global

  def nb_message_scroller(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="NbScroller"
      phx-update="stream"
      class="nb-scroller flex flex-col gap-3 overflow-y-auto"
      {@rest}
    >
      <.nb_message
        :for={{dom_id, message} <- @stream}
        id={dom_id}
        role={message.role}
        tone={Map.get(message, :tone)}
        at={Map.get(message, :at)}
      >
        {message.text}
      </.nb_message>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :role, :string, required: true, doc: "speaker: user | assistant | error | info | system"
  attr :tone, :string, default: nil, doc: "optional palette override (badge tone names)"
  attr :at, :string, default: nil, doc: "optional timestamp line"
  slot :inner_block, required: true

  def nb_message(assigns) do
    assigns = assign(assigns, :tone, assigns.tone || default_tone(assigns.role))

    ~H"""
    <article id={@id} class="nb-message" data-role={@role}>
      <div class="flex items-center gap-2">
        <span class={[
          "inline-flex items-center gap-1.5 rounded-base border-2 border-border px-2 py-0.5 text-xs font-heading uppercase",
          fill(@tone)
        ]}>
          {@role}
        </span>
        <span :if={@at} class="text-foreground/50 text-xs font-mono">{@at}</span>
      </div>
      <div class="whitespace-pre-wrap text-sm font-base text-foreground">
        {render_slot(@inner_block)}
      </div>
    </article>
    """
  end

  # Severity rides the shared palette: errors are loud (red), the user's own
  # words are the loud yellow (main), the assistant speaks on a plain card.
  defp default_tone("user"), do: "main"
  defp default_tone("assistant"), do: "neutral"
  defp default_tone("error"), do: "red"
  defp default_tone("info"), do: "cyan"
  defp default_tone("system"), do: "violet"
  defp default_tone(_other), do: "neutral"

  # Same fills CoreComponents.badge/1 derives from the tone names — one
  # palette, one place.
  defp fill(tone) when tone in ~w(neutral main yellow pink green orange violet cyan red),
    do: "bg-#{tone}"

  defp fill(_other), do: "bg-secondary-background"
end
