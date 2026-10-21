defmodule Storybook.Atlas.TagTwins do
  @moduledoc """
  The renderer question, in one row: the same Tag from HEEx (server-rendered,
  no flash) and from Lit (`<atlas-tag>`, styled once the bundle defines it).
  Both read one recipe, so they should be pixel-identical.
  """

  use PhoenixStorybook.Story, :component

  import Phoenix.Component, only: [sigil_H: 2, assign: 3]

  def function, do: &__MODULE__.pair/1

  def pair(assigns) do
    assigns =
      assigns
      |> assign(:color, assigns[:color] || "blue")
      |> assign(:size, assigns[:size] || "md")
      |> assign(:label, assigns[:label] || "Pending")

    ~H"""
    <div class="flex items-center gap-4 font-sans text-sm">
      <span class="w-20 text-(--atlas-text-secondary)">HEEx</span>
      <Atlas.Components.tag color={@color} size={@size}>{@label}</Atlas.Components.tag>
      <span class="w-20 text-(--atlas-text-secondary)">Lit</span>
      <atlas-tag color={@color} size={@size}>{@label}</atlas-tag>
    </div>
    """
  end

  def variations do
    for color <- ~w(blue gold green orange red neutral)a do
      label = color |> Atom.to_string() |> String.capitalize()
      %Variation{id: color, attributes: %{color: Atom.to_string(color), label: label}}
    end
  end
end
