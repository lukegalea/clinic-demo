defmodule ClinicDemo.Planning.Run do
  @moduledoc """
  One planning run: `AshPlanning.Fragment.Run` on the clinic's base, in table
  `planning_runs`.

  The fragment supplies the axes and the lease. Who may move them:

    * `request` is open to any signed-in member of staff: a person asks for a
      roster.
    * `prepare`, `start`, `renew_lease`, `request_cancel` and `record_result` are
      **machinery-only** (`ClinicDemo.Planning.Machinery`): the planner writes a
      run's axes, lease and result; no person does.

  The clinic has no erasure vault, so `problem_payload` and `result_payload` are
  stored as written. That is acceptable only because every clinic fixture is
  synthetic; a host with real data seals them (see the fragment's moduledoc).
  """

  use Ash.Resource,
    domain: ClinicDemo.Planning,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    fragments: [AshPlanning.Fragment.Run]

  postgres do
    table "planning_runs"
    repo ClinicDemo.Repo

    references do
      reference :model_version, on_delete: :restrict
    end
  end

  relationships do
    belongs_to :model_version, ClinicDemo.Planning.ModelVersion do
      public? true
      define_attribute? false
      description "The pinned model version."
    end

    has_many :candidates, ClinicDemo.Planning.Candidate do
      public? true
      sort index: :asc
      description "What the run proposed."
    end
  end

  policies do
    policy action_type(:read) do
      description "Runs are readable by anything that can reach the application."
      authorize_if always()
    end

    policy action(:request) do
      description "Any signed-in member of staff may ask for a roster."
      authorize_if actor_present()
    end

    policy action([:prepare, :start, :renew_lease, :request_cancel, :record_result]) do
      description "A run's axes, lease and result are the planner's, never a person's."
      authorize_if ClinicDemo.Planning.Checks.Machinery
    end
  end

  @doc """
  The binding this run resolves to: the version valid **as of the run's
  `knowledge_cutoff`**, never the live one. `{:error, :not_prepared}` for a run
  with no cutoff yet.
  """
  @spec resolve_binding(%__MODULE__{}) :: {:ok, struct()} | {:error, term()}
  def resolve_binding(%__MODULE__{knowledge_cutoff: nil}), do: {:error, :not_prepared}

  def resolve_binding(%__MODULE__{} = run) do
    Ash.get(ClinicDemo.Planning.Binding, run.binding_id,
      as_of: run.knowledge_cutoff,
      authorize?: false
    )
  end
end
