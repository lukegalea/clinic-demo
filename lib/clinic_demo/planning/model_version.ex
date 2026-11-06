defmodule ClinicDemo.Planning.ModelVersion do
  @moduledoc """
  One immutable planning model version: `AshPlanning.Fragment.ModelVersion` on
  the clinic's base, in table `planning_model_versions`.

  The fragment supplies the contract (the `(key, version)` identity, the model,
  checker and validator hashes, the capability set, `draft -> published ->
  retired`, immutability after publish). This resource supplies what the
  fragment leaves to the host: the table and the policies.

  Never removed: a run pins a version by id, so a version is retired, not
  destroyed. The fixtures behind the clinic's model are synthetic.
  """

  use Ash.Resource,
    domain: ClinicDemo.Planning,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    fragments: [AshPlanning.Fragment.ModelVersion]

  postgres do
    table "planning_model_versions"
    repo ClinicDemo.Repo
  end

  policies do
    policy action_type(:read) do
      description "Model versions are readable by anything that can reach the application."
      authorize_if always()
    end

    policy action_type([:create, :update]) do
      description "Only a signed-in member of staff may draft, publish or retire a model version."
      authorize_if actor_present()
    end
  end
end
