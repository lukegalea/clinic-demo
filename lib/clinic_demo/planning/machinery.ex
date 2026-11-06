defmodule ClinicDemo.Planning.Machinery do
  @moduledoc """
  The planner's own identity: the actor under which the planning runtime (the
  snapshot builder, the solve runner, the check pipeline) writes a run's axes, its
  candidates and their checks.

  A named non-human actor, for the same reason `ClinicDemo.Rules` has a rule
  deployer: the audit trail should say the planner did it, not nobody. No person
  acts as machinery, and the policies on `Run`, `Candidate` and `CheckResult`
  grant these actions to it and to nobody else
  (`ClinicDemo.Planning.Checks.Machinery`).
  """

  @id "00000000-0000-0000-0000-0000000000b1"

  @doc "The planner's actor."
  @spec actor() :: map()
  def actor, do: %{id: @id, name: "roster planner", planning_machinery: true}

  @doc "Whether `actor` is the planner."
  @spec machinery?(term()) :: boolean()
  def machinery?(%{planning_machinery: true, id: @id}), do: true
  def machinery?(_other), do: false
end
