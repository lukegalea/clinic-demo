defmodule Storybook.Components.Input do
  @moduledoc """
  Stories for `ClinicDemoWeb.CoreComponents.input/1`.

  The input recipe: 2px black border, white fill, 5px radius, black focus
  ring, bold `font-heading` labels. The error variation shows the red ring
  and message the form components fall back to.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &ClinicDemoWeb.CoreComponents.input/1

  def variations do
    [
      %Variation{
        id: :text,
        attributes: %{
          label: "Patient name",
          name: "patient_name",
          type: "text",
          placeholder: "Ada Lovelace"
        }
      },
      %Variation{
        id: :email,
        attributes: %{
          label: "Email",
          name: "email",
          type: "email",
          placeholder: "ada@clinic.example"
        }
      },
      %Variation{
        id: :select,
        description: "Selects share the text input recipe (h-10, white, 2px border).",
        attributes: %{
          label: "Triage urgency",
          name: "triage_urgency",
          type: "select",
          prompt: "Choose…",
          options: [
            {"Routine", "routine"},
            {"Soon", "soon"},
            {"Urgent", "urgent"},
            {"Emergency", "emergency"}
          ]
        }
      },
      %Variation{
        id: :with_error,
        description: "Errors draw a red ring and a bold message under the field.",
        attributes: %{
          label: "Email",
          name: "email",
          type: "email",
          value: "not-an-email",
          errors: ["is not a valid email address"]
        }
      }
    ]
  end
end
