defmodule Storybook.Components.Card do
  @moduledoc """
  Stories for `ClinicDemoWeb.CoreComponents.card/1`.

  The card rests on the black system shadow; an accent recolors only the
  hover lift (black at rest → colored at 6px on hover) and paints a dotted
  strip across the top. Hover each one: the shadow growing in color is the
  delight moment — body fill and border never change.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &ClinicDemoWeb.CoreComponents.card/1

  def variations do
    [
      %Variation{
        id: :plain,
        description:
          "No accent: the floor of the system — white card, black border, black shadow.",
        slots: [
          "<h3 class=\"font-heading\">A quiet card</h3>",
          "<p class=\"text-sm text-foreground/70\">Hover grows the black shadow to 6px; pressing down sinks it to 2px.</p>"
        ]
      },
      %VariationGroup{
        id: :accents,
        description: "Accent cards: dotted header strip + colored lift on hover.",
        variations:
          for accent <- ~w(main yellow pink green orange violet cyan red) do
            %Variation{
              id: String.to_atom(accent),
              attributes: %{accent: accent},
              slots: [
                "<h3 class=\"font-heading\">accent=#{inspect(accent)}</h3>",
                "<p class=\"text-sm text-foreground/70\">Hover me — the shadow grows in the accent color.</p>"
              ]
            }
          end
      },
      %Variation{
        id: :as_link,
        description: "With href the card renders as a link (how the operator hub uses it).",
        attributes: %{accent: "violet", href: "/operator"},
        slots: [
          "<h3 class=\"font-heading\">Operator hub</h3>",
          "<p class=\"text-sm text-foreground/70\">A clickable card, same recipe.</p>"
        ]
      }
    ]
  end
end
