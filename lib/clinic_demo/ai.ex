defmodule ClinicDemo.AI do
  @moduledoc """
  The agent-facing domain: interpretation only.

  Everything it holds returns a value rather than changing anything. The
  console this domain serves is read-only by construction: it shows a declared
  surface, composes one from a validated spec, or answers a question in words.
  There is no write path to reach, which is what makes prompt injection
  uninteresting here rather than merely discouraged.

  No tables. These resources exist so prompt-backed actions can live somewhere
  sensible, not because "AI" is a part of the domain model.
  """

  use Ash.Domain, otp_app: :clinic_demo, validate_config_inclusion?: false

  resources do
    # No tables. RequestClassifier exists only to give the prompt-backed
    # actions a home, because Ash puts generic actions on resources rather
    # than domains. Their return types (Intent, SurfaceSpec, Answer) are
    # TypedStructs -- types, not resources -- and so do not belong here.
    resource ClinicDemo.AI.RequestClassifier
  end

  @doc """
  The model used for interpretation.

  Configurable so a deployment can choose its provider and tier without editing
  the action. This is a classification task over short text, so a small fast
  model is the right default — the expensive judgement in this flow is the
  clinician reading the answer, not the model writing it.
  """
  def model do
    Application.get_env(:clinic_demo, :ai)[:interpreter_model] ||
      "anthropic:claude-haiku-4-5-20251001"
  end
end
