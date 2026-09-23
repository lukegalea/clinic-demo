defmodule Storybook.Components.Palette do
  @moduledoc """
  The palette and texture sheet, rendered through the components that
  carry them — the reference for "which color, which pattern, how loud".

  Swatches show each vivid secondary with the system's black ink (the only
  ink); the pattern tiles show the currentColor-drawn textures (`bg-dots`,
  `bg-checks`, `bg-stripes`, `bg-grid`) at typical densities. Pattern
  color always comes from a text-* utility on the same element.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &ClinicDemoWeb.CoreComponents.card/1

  def variations do
    [
      %Variation{
        id: :swatches,
        description: "Every vivid secondary, one tile each, all carrying black ink.",
        slots: [
          """
          <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <div class="flex h-16 items-center justify-center rounded-base border-2 border-border bg-main text-sm font-base">main</div>
            <div class="flex h-16 items-center justify-center rounded-base border-2 border-border bg-yellow text-sm font-base">yellow</div>
            <div class="flex h-16 items-center justify-center rounded-base border-2 border-border bg-pink text-sm font-base">pink</div>
            <div class="flex h-16 items-center justify-center rounded-base border-2 border-border bg-green text-sm font-base">green</div>
            <div class="flex h-16 items-center justify-center rounded-base border-2 border-border bg-orange text-sm font-base">orange</div>
            <div class="flex h-16 items-center justify-center rounded-base border-2 border-border bg-violet text-sm font-base">violet</div>
            <div class="flex h-16 items-center justify-center rounded-base border-2 border-border bg-cyan text-sm font-base">cyan</div>
            <div class="flex h-16 items-center justify-center rounded-base border-2 border-border bg-red text-sm font-base">red</div>
          </div>
          """
        ]
      },
      %Variation{
        id: :patterns,
        description:
          "Textures are drawn in currentColor — the text-* utility sets both color and (via opacity) density.",
        slots: [
          """
          <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <div class="h-16 rounded-base border-2 border-border bg-main bg-dots text-foreground/20"></div>
            <div class="h-16 rounded-base border-2 border-border bg-yellow bg-stripes text-foreground/15"></div>
            <div class="h-16 rounded-base border-2 border-border bg-violet bg-checks text-foreground/10"></div>
            <div class="h-16 rounded-base border-2 border-border bg-cyan bg-grid text-foreground/20"></div>
          </div>
          """
        ]
      },
      %Variation{
        id: :colored_shadows,
        description:
          "Colored hard shadows — the accent pattern. Used on hover for accent cards; here at rest to show the pairs.",
        slots: [
          """
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div class="rounded-base border-2 border-border bg-black px-4 py-3 text-sm font-base text-white shadow-yellow">Black card, yellow shadow</div>
            <div class="rounded-base border-2 border-border bg-secondary-background px-4 py-3 text-sm font-base shadow-pink">White card, pink shadow</div>
            <div class="rounded-base border-2 border-border bg-violet px-4 py-3 text-sm font-base shadow-black/40">Violet card, translucent-black shadow</div>
            <div class="rounded-base border-2 border-border bg-main px-4 py-3 text-sm font-base shadow-lift">Blue card, 6px black lift</div>
          </div>
          """
        ]
      }
    ]
  end
end
