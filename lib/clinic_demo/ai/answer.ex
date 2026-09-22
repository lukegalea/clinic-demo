defmodule ClinicDemo.AI.Answer do
  @moduledoc """
  The grounded answer `ClinicDemo.AI.RequestClassifier.answer_question/1`
  returns.

  A plain typed struct with no behaviour, mirroring `ClinicDemo.AI.Intent` and
  `ClinicDemo.AI.SurfaceSpec`: an action's return type has to be an Ash type,
  and this one exists only to carry the answer — one `:text` field is the whole
  shape. The struct also **is** the schema: `ash_ai` derives the JSON schema
  the model is constrained to from these field definitions, so there is no
  separate schema to drift.
  """

  use Ash.TypedStruct

  @type t :: %__MODULE__{
          text: String.t()
        }

  typed_struct do
    field :text, :string,
      allow_nil?: false,
      constraints: [min_length: 1],
      description:
        "The answer, in one or two plain sentences drawn only from the sources given " <>
          "in the prompt."
  end
end
