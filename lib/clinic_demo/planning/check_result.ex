defmodule ClinicDemo.Planning.CheckResult do
  @moduledoc """
  One check of one candidate: `AshPlanning.Fragment.CheckResult` on the clinic's
  base, in table `planning_check_results`. Create-only; a re-check is a new row.

  The MiniZinc solution checker and the independent Elixir validator are
  recorded separately, as status and reason codes in clear columns. `record` is
  machinery-only: the check pipeline writes it.
  """

  use Ash.Resource,
    domain: ClinicDemo.Planning,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    fragments: [AshPlanning.Fragment.CheckResult]

  postgres do
    table "planning_check_results"
    repo ClinicDemo.Repo

    references do
      reference :candidate, on_delete: :restrict
    end
  end

  relationships do
    belongs_to :candidate, ClinicDemo.Planning.Candidate do
      public? true
      define_attribute? false
      description "The candidate that was checked."
    end
  end

  policies do
    policy action_type(:read) do
      description "Check results are readable by anything that can reach the application."
      authorize_if always()
    end

    policy action(:record) do
      description "The check pipeline writes check results; no person does."
      authorize_if ClinicDemo.Planning.Checks.Machinery
    end
  end
end
