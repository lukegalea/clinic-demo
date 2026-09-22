defmodule ClinicDemo.AI.Intent do
  @moduledoc """
  What the model understood a request to mean.

  A plain typed struct with no behaviour, deliberately. It is the *only* thing
  the model produces, and it cannot do anything — it names an intent and the
  surface it mentioned. Carrying it out is `ClinicDemo.AI.Interpreter`'s job,
  and every intent this console supports resolves to a read: a declared
  surface, a composed one, or an answer in words. Nothing the model can return
  changes a row, which is a structural fact about this struct rather than a
  promise in a prompt.

  The struct also **is** the schema: `ash_ai` derives the JSON schema the model
  is constrained to from these field definitions, so there is no separate schema
  to drift. Adding a field here changes what the model may return, with no
  second place to edit.
  """

  use Ash.TypedStruct

  # Hand-written because `Ash.TypedStruct` does not emit one -- the `@type t` in
  # that module belongs to its own `Field` entity, not to the struct it builds.
  # Without this, every `@spec` naming `Intent.t()` is an unknown type, which is
  # a Dialyzer error rather than a silent no-op.
  @type t :: %__MODULE__{
          kind: :show_surface | :design_surface | :ask_question | :unknown,
          surface: String.t() | nil,
          reasoning: String.t() | nil
        }

  typed_struct do
    field :kind, :atom,
      constraints: [one_of: [:show_surface, :design_surface, :ask_question, :unknown]],
      allow_nil?: false,
      description: "What the user is asking for. Use :unknown if it is not a supported request."

    field :surface, :string,
      description:
        "For :show_surface, the name of the declared surface that answers the request. " <>
          "Must be one of the names listed in the prompt, copied exactly."

    field :reasoning, :string,
      description: "One sentence explaining the interpretation, shown to the human for review."
  end
end
