defmodule Storybook.Components.Badge do
  @moduledoc """
  Stories for `ClinicDemoWeb.CoreComponents.badge/1` — the sticker-style
  badge.

  Two vocabularies, one shape: `status` speaks the clinic's lane language
  (booked/low/…/closed — the same colors everywhere a vet sees them), and
  `tone` picks any palette color for everything else (hero stickers,
  section chips). `sticker` adds the hard shadow + white halo; rotation is
  deliberately the caller's job — tilt each one differently.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &ClinicDemoWeb.CoreComponents.badge/1

  def variations do
    [
      %VariationGroup{
        id: :statuses,
        description: "The board-lane vocabulary — a color a vet can parse at a glance.",
        variations:
          for status <- ~w(booked low medium high emergency visit discharged closed) do
            %Variation{
              id: String.to_atom(status),
              attributes: %{status: status},
              slots: [String.capitalize(status)]
            }
          end
      },
      %VariationGroup{
        id: :tones,
        description: "Plain palette tones for non-clinic labels.",
        variations:
          for tone <- ~w(neutral main yellow pink green orange violet cyan red) do
            %Variation{
              id: String.to_atom(tone),
              attributes: %{tone: tone},
              slots: [tone]
            }
          end
      },
      %VariationGroup{
        id: :stickers,
        description:
          "Sticker mode (shadow + white halo) with caller-chosen rotations — never all the same tilt.",
        variations: [
          %Variation{
            id: :tilt_left,
            attributes: %{tone: "yellow", sticker: true, class: "-rotate-2"},
            slots: ["Ash 3"]
          },
          %Variation{
            id: :tilt_right,
            attributes: %{tone: "pink", sticker: true, class: "rotate-2"},
            slots: ["LiveView 1.2"]
          },
          %Variation{
            id: :status_sticker,
            attributes: %{status: "high", sticker: true, class: "rotate-1"},
            slots: ["High"]
          }
        ]
      }
    ]
  end
end
