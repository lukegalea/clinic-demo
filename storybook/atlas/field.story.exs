defmodule Storybook.Atlas.Field do
  @moduledoc """
  Atlas Field around a native Input, for HEEx forms: `Atlas.Forms.field/1`.
  Same Input/Field recipes as `<atlas-text-field>`. Errors show only once the
  field has been used, and are linked by aria-describedby.

  French labels are the Atlas Bilingual page's real pairs; the caption has
  none, so it stays English.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &Atlas.Forms.field/1

  def variations do
    [
      %Variation{
        id: :default,
        attributes: %{
          field: field(%{"pm" => ""}),
          label: "PM Id(s)",
          caption: "Shown to vendors on the invitation.",
          required: true
        }
      },
      %Variation{
        id: :filled,
        attributes: %{field: field(%{"pm" => "PM-1042"}), label: "PM Id(s)", required: true}
      },
      %Variation{
        id: :invalid,
        description: "Used, then failed validation: red border plus the message.",
        attributes: %{
          field: field(%{"pm" => "ab"}, pm: {"must be at least 3 characters", []}),
          label: "PM Id(s)",
          caption: "Shown to vendors on the invitation.",
          required: true
        }
      },
      %Variation{
        id: :french,
        description: "A 663% longer label: the label wraps, the input truncates.",
        attributes: %{
          field: field(%{"pm" => ""}),
          label: "Numéro(s) d’identification du Gestionnaire immobilier",
          required: true
        }
      }
    ]
  end

  defp field(params, errors \\ []) do
    form = Phoenix.Component.to_form(params, as: :story, errors: errors, action: :validate)
    form[:pm]
  end
end
