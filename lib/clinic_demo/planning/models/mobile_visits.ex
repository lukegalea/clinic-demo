defmodule ClinicDemo.Planning.Models.MobileVisits do
  @moduledoc """
  The declaration of the clinic's mobile-visits model: which reviewed artifacts it
  is, and where they live.

    * the model, `priv/planning/mobile_visits.mzn` (synthetic and public);
    * its solution checker, `priv/planning/mobile_visits.mzc.mzn`;
    * the independent validator, `ClinicDemo.Planning.MobileValidator`;
    * the limits a solve runs under.

  It plans **one veterinarian's one day**: a bounded set of mobile visits, each with
  an explicit window, between the clinic (where the day starts and ends) and clients'
  addresses, around the veterinarian's pinned in-clinic work and blocked time, with
  every leg of travel an explicit interval priced from the pinned
  `ClinicDemo.Scheduling.TravelMatrix`. A pair the matrix marks unreachable is
  refused, never cheap. There is no parameter decision: the model's parameters are
  its inputs (windows, commitments, matrix).

  Like `ClinicDemo.Planning.Models.WeeklyRoster`, the three file artifacts are
  content-hashed **at compile time** (`@external_resource`), so a `ModelVersion`
  row's hashes are those of the code that is running; editing the model, the checker
  or the validator is a new version that must be published and bound before a plan
  can use it. The rest of `ClinicDemo.Planning.Model` is `ClinicDemo.Planning.MobilePlan`.
  """

  @behaviour ClinicDemo.Planning.Model

  alias ClinicDemo.Planning.MobilePlan

  @model_rel "priv/planning/mobile_visits.mzn"
  @checker_rel "priv/planning/mobile_visits.mzc.mzn"
  @validator_source Path.expand("../mobile_validator.ex", __DIR__)

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

  @key "mobile_visits"
  @purpose "planning.mobile_visits"
  @purpose_atom :"planning.mobile_visits"

  # What a solve may use: Solverl's own wall-clock limits plus the memory ceiling
  # `prlimit` enforces. Structural values only; no input data.
  @backend_profile %{
    "solver" => "gecode",
    "time_limit_ms" => 60_000,
    "solution_timeout_ms" => 30_000,
    "memory_bytes" => 1_000_000_000
  }

  @capabilities [:integer_variables, :routing, :time_windows, :no_overlap]

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
      validator: ClinicDemo.Planning.MobileValidator,
      validator_sha256: @validator_sha256,
      decision_key: nil,
      capabilities: @capabilities,
      backend_profile: @backend_profile
    }
  end

  @impl true
  defdelegate scope(opts), to: MobilePlan

  @impl true
  defdelegate build(run, opts, cutoff, definitions), to: MobilePlan

  @impl true
  defdelegate decode(payload, answer), to: MobilePlan

  @impl true
  defdelegate summarize(assignments, payload, candidate), to: MobilePlan

  @impl true
  defdelegate obligations(assignments), to: MobilePlan

  @impl true
  defdelegate validate(problem, assignments), to: MobilePlan

  @impl true
  defdelegate current_inputs(payload), to: MobilePlan

  @impl true
  defdelegate apply_plan(candidate, payload, actor), to: MobilePlan
end
