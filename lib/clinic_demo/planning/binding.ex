defmodule ClinicDemo.Planning.Binding do
  @moduledoc """
  The clinic's binding of `(model_key, purpose)` to the definitions a roster is
  planned with: `AshPlanning.Fragment.Binding` on the clinic's base, in table
  `planning_bindings`.

  Temporal: re-binding closes the version valid until `as_of` and opens a new
  one, so a snapshot built `as_of` its knowledge cutoff resolves the binding that
  was valid then. A run names its binding by id with no database foreign key (a
  temporal key is `(id, valid_at)`, which an ordinary column cannot reference);
  `ClinicDemo.Planning.Run.resolve_binding/1` reads it as of the run's cutoff,
  never the live one.
  """

  use Ash.Resource,
    domain: ClinicDemo.Planning,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    fragments: [AshPlanning.Fragment.Binding]

  postgres do
    table "planning_bindings"
    repo ClinicDemo.Repo
  end

  policies do
    policy action_type(:read) do
      description "Bindings are readable by anything that can reach the application."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only a signed-in member of staff may bind or rebind a model."
      authorize_if actor_present()
    end
  end
end
