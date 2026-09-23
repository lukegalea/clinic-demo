defmodule ClinicDemo.Scheduling.VisitMachine do
  @moduledoc """
  Read-only views of the Appointment lifecycle's formal machine.

  The machine itself is declared on `ClinicDemo.Scheduling.Appointment` (the
  `state_machine` block) — that resource is the one authority on which status
  moves are legal. This module exists so the *shape* of the machine can be
  shown to a person: the chart is derived from the declaration, so a
  transition added to the resource shows up here with no second edit.
  """

  alias ClinicDemo.Scheduling.Appointment

  @doc """
  The lifecycle as a mermaid state diagram (source text).

  Rendered on the operator hub. A richer home — a live diagram inside the
  Clarity introspection tool, next to the module and policy graphs — is a
  queued follow-up.
  """
  @spec chart() :: String.t()
  def chart do
    AshStateMachine.Charts.mermaid_state_diagram(Appointment)
  end

  @doc """
  The same machine as a mermaid flowchart (source text).
  """
  @spec flowchart() :: String.t()
  def flowchart do
    AshStateMachine.Charts.mermaid_flowchart(Appointment)
  end
end
