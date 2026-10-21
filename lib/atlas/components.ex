defmodule Atlas.Components do
  @moduledoc """
  HEEx twins of the static Atlas components, generated at compile time from
  `priv/atlas/recipes.json` (written from the Lit recipes by
  `mix atlas.recipes`).

  Only recipes of kind `"static"` get a twin: they have no behaviour, so the
  server can render them completely, with exactly the classes the Lit element
  uses. That is what the shell, emails, PDFs and first paint need. Interactive
  components exist only as Lit elements.

  Each twin takes one attribute per Figma variant axis, constrained to that
  axis's values, plus global attributes and an inner block:

      <Atlas.Components.tag color="gold">Pending</Atlas.Components.tag>
  """

  use Phoenix.Component

  @recipes_path Path.join([__DIR__, "..", "..", "priv", "atlas", "recipes.json"])
  @external_resource @recipes_path
  @recipes @recipes_path |> File.read!() |> Jason.decode!()

  @doc false
  def recipes, do: @recipes

  @doc "Resolves a recipe for one set of props: the classes and the `data-atlas` tag."
  def resolve(%{"variants" => variants, "defaults" => defaults} = recipe, props) do
    chosen =
      for {axis, values} <- Enum.sort(variants) do
        value = to_string(Map.get(props, String.to_existing_atom(axis)) || defaults[axis])
        value = if Map.has_key?(values, value), do: value, else: defaults[axis]
        {axis, value}
      end

    classes =
      Enum.join([recipe["base"] | Enum.map(chosen, fn {axis, v} -> variants[axis][v] end)], " ")

    tag = Enum.join([recipe["name"] | Enum.map(chosen, &elem(&1, 1))], "/")
    {classes, tag}
  end

  # Fixed allow-lists from recipe names and Figma axes to atoms: recipes.json
  # is generated, so an unknown name or axis fails the compile here instead
  # of minting atoms from file contents (Iron Law #10).
  @functions %{"Tag" => :tag}
  @axes %{
    "color" => :color,
    "size" => :size,
    "state" => :state,
    "variant" => :variant,
    "part" => :part
  }

  @doc "The twin's function name for a recipe name, or nil when it has none."
  def function_name(name), do: Map.get(@functions, name)

  for {name, %{"kind" => "static"} = recipe} <- @recipes do
    fun =
      Map.get(@functions, name) ||
        raise "Atlas.Components: no twin name for static recipe #{inspect(name)}; add it to @functions"

    @recipe recipe

    @doc "Atlas #{name} (Figma set `#{recipe["figmaSet"]}`), generated from its recipe."
    for {axis, values} <- Enum.sort(recipe["variants"]) do
      attr Map.fetch!(@axes, axis), :string,
        default: recipe["defaults"][axis],
        values: Map.keys(values)
    end

    attr :class, :string, default: nil, doc: "layout classes only (margin, placement)"
    attr :rest, :global
    slot :inner_block, required: true

    def unquote(fun)(assigns) do
      {classes, tag} = resolve(@recipe, assigns)
      assigns = assign(assigns, atlas_class: [classes, assigns.class], atlas_tag: tag)

      ~H"""
      <span class={@atlas_class} data-atlas={@atlas_tag} {@rest}>{render_slot(@inner_block)}</span>
      """
    end
  end
end
