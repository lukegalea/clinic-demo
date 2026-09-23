defmodule Storybook.Components.Button do
  @moduledoc """
  Stories for `ClinicDemoWeb.CoreComponents.button/1`.

  Three fills — white default (neutral), accent-blue `primary`, and the
  loud yellow `accent` (one per page, for the call-to-action) — plus the
  link form. All share the motion pair: hover grows the hard shadow in
  place, press nudges down into a 2px shadow.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &ClinicDemoWeb.CoreComponents.button/1

  def variations do
    [
      %Variation{
        id: :neutral,
        attributes: %{},
        slots: ["Cancel"]
      },
      %Variation{
        id: :primary,
        attributes: %{variant: "primary"},
        slots: ["Save appointment"]
      },
      %Variation{
        id: :accent,
        description: "The yellow pop — reserve it for the single loudest action on a page.",
        attributes: %{variant: "accent"},
        slots: ["Get Started"]
      },
      %Variation{
        id: :as_link,
        description: "With a navigate attribute the same recipe renders a link.",
        attributes: %{navigate: "/"},
        slots: ["Board"]
      }
    ]
  end
end
