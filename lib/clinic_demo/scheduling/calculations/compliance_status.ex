defmodule ClinicDemo.Scheduling.Calculations.ComplianceStatus do
  @moduledoc """
  The appointment row's compliance badge value, batched per page.

  A module-based calculation on purpose: `calculate/3` receives the whole
  batch of records the surface's read just loaded, so the expensive part of
  the status query — the active policy bundle read and its IR decode — runs
  once per page, not once per row. Each row's own evaluation is in-memory
  (`AshCompliance.status_for/2` with the shared pre-decoded bundle via its
  `:bundle` option), which is exactly the "one pass over rows" a board
  page-load can afford and a per-row `expr` calculation could never be.

  The fact construction is the fact builder's job
  (`ClinicDemo.Compliance.AppointmentFacts`); the rules probe the record the
  way the guard probes a transition, against `transition_to: :checked_in` —
  the row badge answers "would check-in be refused?".

  Declares the `:patient` load so the weight predicate reads a preloaded
  relationship instead of re-querying per row.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:patient]

  @impl true
  def calculate(records, _opts, _context) do
    ClinicDemo.Compliance.appointment_status_page(records)
  end
end
