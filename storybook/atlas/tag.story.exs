defmodule Storybook.Atlas.Tag do
  @moduledoc """
  Atlas Tag (Figma set "Tag"), the HEEx twin: `Atlas.Components.tag/1`,
  generated at compile time from the Lit recipe (`assets/js/atlas/tag.recipe.js`
  → `priv/atlas/recipes.json`). Every colour × size the recipe declares.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &Atlas.Components.tag/1

  def variations do
    [
      %VariationGroup{
        id: :colors,
        description: "Every colour, size md.",
        variations:
          for color <- ~w(blue gold green orange red neutral)a do
            %Variation{
              id: color,
              attributes: %{color: Atom.to_string(color), size: "md"},
              slots: [color |> Atom.to_string() |> String.capitalize()]
            }
          end
      },
      %VariationGroup{
        id: :sizes,
        description: "sm 24px, md 28px, lg 32px.",
        variations:
          for size <- ~w(sm md lg)a do
            %Variation{
              id: size,
              attributes: %{color: "blue", size: Atom.to_string(size)},
              slots: ["Size #{size}"]
            }
          end
      },
      %Variation{
        id: :french,
        description: "Bilingual rule for Tag: it grows, never truncates or abbreviates.",
        attributes: %{color: "gold", size: "md"},
        slots: ["Ajouter un Gestionnaire immobilier"]
      }
    ]
  end
end
