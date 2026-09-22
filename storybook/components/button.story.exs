defmodule Storybook.Components.Button do
  @moduledoc """
  Stories for `ClinicDemoWeb.CoreComponents.button/1`.

  Shows both neobrutalist fills — the accent-blue `primary` variant and
  the white default (neutral) — plus the link form, all carrying the
  signature hover "press" (slide one shadow-width, shadow collapses).
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
        id: :as_link,
        description: "With a navigate attribute the same recipe renders a link.",
        attributes: %{navigate: "/"},
        slots: ["Board"]
      }
    ]
  end
end
