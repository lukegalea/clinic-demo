defmodule ClinicDemo.Canvas.Registry do
  @moduledoc """
  The canvas registry for this application: the catalogue of what the
  `/canvas` object graph knows to exist.

  The registry is the entire discovery surface (`CANVAS-SEC-005` in the
  library's terms). `domains/0` lists the compile-known Ash domains the
  graph may traverse, and nothing outside that list resolves — what the
  registry does not name does not exist, and no client input can widen it.

  `projections/2` is where the application claims capabilities the library
  cannot derive from action shape alone. `:diagram` is claimed only where a
  renderer actually exists — the bpmn-js designer for
  `ClinicDemo.Visits.Process` and the dmn-js editor for
  `ClinicDemo.Decisions.DecisionTable` — because a projection is a promise the
  object model makes on the application's behalf, and claiming it for a
  resource nothing can draw would render a badge with nothing behind it.
  Every other target returns `nil`, which keeps the library's derived
  projections untouched.
  """

  @behaviour AshA2ui.Canvas.Registry

  @impl true
  def domains do
    [ClinicDemo.Scheduling, ClinicDemo.Decisions, ClinicDemo.Visits]
  end

  @impl true
  def label(:application), do: "Clinic Demo"
  def label(_other), do: nil

  @impl true
  def projections(ClinicDemo.Visits.Process, derived), do: derived ++ [:diagram]
  def projections(ClinicDemo.Decisions.DecisionTable, derived), do: derived ++ [:diagram]
  def projections(_other, _derived), do: nil
end
