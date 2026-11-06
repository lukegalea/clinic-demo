defmodule ClinicDemo.Planning.Checks.Machinery do
  @moduledoc "Passes only for the planner's own actor (`ClinicDemo.Planning.Machinery`)."

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the actor is the roster planner"

  @impl true
  def match?(actor, _context, _opts), do: ClinicDemo.Planning.Machinery.machinery?(actor)
end
