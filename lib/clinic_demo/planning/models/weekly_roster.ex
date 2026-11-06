defmodule ClinicDemo.Planning.Models.WeeklyRoster do
  @moduledoc """
  The declaration of the clinic's weekly staffing model: which reviewed artifacts
  it is, and where they live.

    * the model, `priv/planning/weekly_roster.mzn` (synthetic and public);
    * its solution checker, `priv/planning/weekly_roster.mzc.mzn`;
    * the independent validator, `ClinicDemo.Planning.RosterValidator`;
    * the parameter decision, `staffing.policy`;
    * the limits a solve runs under.

  The three file artifacts are content-hashed **at compile time**
  (`@external_resource`), so a `ModelVersion` row's hashes are those of the code
  that is running, and editing the model, the checker or the validator is a new
  version that must be published and bound before a plan can use it. There is no
  Spark-to-MiniZinc compiler: the model is a document, and the hashes are how a
  plan says which one it was made with.

  When `AshPlanning` ships its `model :key do ... end` extension (deferred, see
  `AshPlanning` and its `docs/REVERSAL.md`), this module's `definition/0` is what
  that declaration will name; nothing else changes.
  """

  @behaviour ClinicDemo.Planning.Model

  alias ClinicDemo.Planning.RosterPlan

  @model_rel "priv/planning/weekly_roster.mzn"
  @checker_rel "priv/planning/weekly_roster.mzc.mzn"
  @validator_source Path.expand("../roster_validator.ex", __DIR__)

  @model_source Path.expand("../../../../#{@model_rel}", __DIR__)
  @checker_source Path.expand("../../../../#{@checker_rel}", __DIR__)

  @external_resource @model_source
  @external_resource @checker_source
  @external_resource @validator_source

  @model_sha256 :crypto.hash(:sha256, File.read!(@model_source)) |> Base.encode16(case: :lower)
  @checker_sha256 :crypto.hash(:sha256, File.read!(@checker_source))
                  |> Base.encode16(case: :lower)
  @validator_sha256 :crypto.hash(:sha256, File.read!(@validator_source))
                    |> Base.encode16(case: :lower)

  @key "weekly_roster"
  @purpose "planning.weekly_roster"
  @purpose_atom :"planning.weekly_roster"

  # What a solve may use: Solverl's own wall-clock limits plus the memory ceiling
  # `prlimit` enforces. Structural values only; no input data.
  @backend_profile %{
    "solver" => "gecode",
    "time_limit_ms" => 60_000,
    "solution_timeout_ms" => 30_000,
    "memory_bytes" => 1_000_000_000
  }

  @capabilities [:integer_variables, :no_overlap, :time_windows]

  @doc "The model's key."
  @spec key() :: String.t()
  def key, do: @key

  @doc "The purpose the model is bound under."
  @spec purpose() :: String.t()
  def purpose, do: @purpose

  @doc "The declaration: artifacts, hashes, validator, capabilities and limits."
  @impl true
  @spec definition() :: map()
  def definition do
    %{
      key: @key,
      purpose: @purpose,
      purpose_atom: @purpose_atom,
      model_path: Application.app_dir(:clinic_demo, @model_rel),
      checker_path: Application.app_dir(:clinic_demo, @checker_rel),
      model_sha256: @model_sha256,
      checker_sha256: @checker_sha256,
      validator: ClinicDemo.Planning.RosterValidator,
      validator_sha256: @validator_sha256,
      decision_key: "staffing.policy",
      capabilities: @capabilities,
      backend_profile: @backend_profile
    }
  end

  # The rest of `ClinicDemo.Planning.Model` is the roster's plan, in `RosterPlan`.
  @impl true
  defdelegate scope(opts), to: RosterPlan

  @impl true
  defdelegate build(run, opts, cutoff, definitions), to: RosterPlan

  @impl true
  defdelegate decode(payload, answer), to: RosterPlan

  @impl true
  defdelegate summarize(assignments, payload, candidate), to: RosterPlan

  @impl true
  defdelegate obligations(assignments), to: RosterPlan

  @impl true
  defdelegate validate(problem, assignments), to: RosterPlan

  @impl true
  defdelegate current_inputs(payload), to: RosterPlan

  @impl true
  defdelegate apply_plan(candidate, payload, actor), to: RosterPlan
end
