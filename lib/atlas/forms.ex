defmodule Atlas.Forms do
  @moduledoc """
  Atlas form controls for HEEx pages: native elements with Atlas classes,
  taken from the same recipes as the Lit elements (`priv/atlas/recipes.json`).

  `field/1` is the Atlas Field composition (Figma set
  4d90d30eae1c60af2204d69aeb05af2290244d23) around a native Input: a visible
  label, an optional caption, and the error linked through
  `aria-describedby`, so it is read when focus lands (Accessibility page:
  "errors are announced, not just shown"). Errors show only once the input
  has been used, as LiveView forms do.
  """

  use Phoenix.Component

  @recipes Atlas.Components.recipes()
  @input @recipes["Input"]
  @field @recipes["Field"]

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :caption, :string, default: nil
  attr :required, :boolean, default: false
  attr :rest, :global, include: ~w(type placeholder autocomplete maxlength disabled)

  def field(assigns) do
    errors = if Phoenix.Component.used_input?(assigns.field), do: assigns.field.errors, else: []
    id = assigns.field.id
    state = if errors == [], do: "default", else: "invalid"
    {input_class, input_tag} = Atlas.Components.resolve(@input, %{state: state})

    assigns =
      assign(assigns,
        errors: Enum.map(errors, &translate/1),
        input_class: input_class,
        input_tag: input_tag,
        caption_id: "#{id}-caption",
        error_id: "#{id}-error",
        part: fn part -> part(part) end
      )

    ~H"""
    <div class={@part.(:root)} data-atlas="Field">
      <label for={@field.id} class={@part.(:label)}>
        {@label}<span :if={@required} class={@part.(:required)} aria-hidden="true"> *</span>
      </label>
      <input
        id={@field.id}
        name={@field.name}
        value={Phoenix.HTML.Form.normalize_value("text", @field.value)}
        class={@input_class}
        data-atlas={@input_tag}
        aria-required={@required && "true"}
        aria-invalid={@errors != [] && "true"}
        aria-describedby={describedby(@caption && @caption_id, @errors != [] && @error_id)}
        {@rest}
      />
      <p :if={@caption} id={@caption_id} class={@part.(:caption)}>{@caption}</p>
      <p :if={@errors != []} id={@error_id} class={@part.(:error)}>{Enum.join(@errors, " ")}</p>
    </div>
    """
  end

  defp part(part) do
    {classes, _} = Atlas.Components.resolve(@field, %{part: to_string(part)})
    classes
  end

  defp describedby(a, b), do: [a, b] |> Enum.filter(& &1) |> Enum.join(" ") |> nil_if_empty()
  defp nil_if_empty(""), do: nil
  defp nil_if_empty(ids), do: ids

  # POC: messages arrive already translated from the lab's validation.
  defp translate({message, _opts}), do: message
  defp translate(message) when is_binary(message), do: message
end
