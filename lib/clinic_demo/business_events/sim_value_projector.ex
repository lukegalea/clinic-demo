defmodule ClinicDemo.BusinessEvents.SimValueProjector do
  @moduledoc """
  The scenario projector (BPSim BD-5): drains one simulation run's twin
  feed into `ClinicDemo.BusinessEvents.SimValueProjection` — and ONLY
  there.

  This module is load-bearing, not convenience (design risk #2):
  `drain_simulation/2` isolates the *feed and the checkpoint* — the twin
  table, the `sim:`-namespaced cursor — but the projection *target* is
  the host's choice, and pointing a sim drain at the real value
  projection would write future-dated, fabricated periods into the
  clinic's actual revenue fold, where any as-of(future) read and every
  real rebuild would fold them in. The ruling, in one line: **the real
  projector (BD-3's) and this one share the fold's handlers
  (`VisitProjectionOps`), never the target table.**

  What isolation means here, concretely:

    * this projector's `drain_simulation(run, :clinic)` reads only
      `Ledger.SimulationEvent` rows labeled `run`, under checkpoints
      named `sim:sim_value_projection_v1.clinic:<run>` — no real drain's
      cursor aliases one, and two runs never share;
    * its `projection_resource` is the sim table alone — the real value
      projection is not an input this module can even name;
    * two knobs are two runs: the generator's content-addressed labels
      keep each run's stream, cursor and periods separate.

  Plain `drain/2` (the real-ledger drain every projector module also
  carries) has no caller in this application: the sim table is a
  scenario target, not a live one. It remains the package's standard
  surface, unmodified.
  """

  use AshDiscreteBusinessEvents.Projections,
    name: "sim_value_projection_v1",
    event_log: ClinicDemo.BusinessEvents.Ledger,
    projection_resource: ClinicDemo.BusinessEvents.SimValueProjection

  alias ClinicDemo.BusinessEvents.VisitProjectionOps

  grain(fn event -> %{region: event.region, subject: event.record_id} end)

  # The shared fold: the same handlers the real value projector uses,
  # pointed at the sim table. Scenario events are terminal outcomes
  # (completed / cancelled / no_show); the other routes exist so the
  # fold is total over the six canonical kinds.
  project("visit_booked", &VisitProjectionOps.ops_for/1)
  project("visit_triaged", &VisitProjectionOps.ops_for/1)
  project("visit_completed", &VisitProjectionOps.ops_for/1)
  project("visit_cancelled", &VisitProjectionOps.ops_for/1)
  project("visit_no_show", &VisitProjectionOps.ops_for/1)
  project("charge_written_off", &VisitProjectionOps.ops_for/1)
end
