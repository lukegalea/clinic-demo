defmodule Storybook.Components.EmptyState do
  @moduledoc """
  Stories for `ClinicDemoWeb.CoreComponents.empty_state/1`.

  The dashed panel for "nothing here yet": dashes say the space is
  waiting, the dotted tile keeps it from reading as an unfinished card.
  Swap the icon to match the neighborhood (a heart for visits, a graph
  node for the canvas).
  """

  use PhoenixStorybook.Story, :component

  def function, do: &ClinicDemoWeb.CoreComponents.empty_state/1

  def variations do
    [
      %Variation{
        id: :default,
        slots: ["No visit processes yet — book an appointment and one starts here."]
      },
      %Variation{
        id: :with_custom_icon,
        description: "Any heroicon name fits in the tile.",
        attributes: %{icon: "hero-cube-transparent"},
        slots: ["Nothing published yet — draw a process and publish it."]
      }
    ]
  end
end
