defmodule ClinicDemoWeb.A2ui.RosterUI do
  @moduledoc """
  The roster: the week as a gantt, the shifts it was carried out with, and
  the plans that proposed them.

  The gantt is the industry-standard roster shape — per-person timeline rows
  with a coverage band (Kronos/UKG, Odoo Planning, Timefold) — rendered
  through the kit's existing live-diagram part; no Atlas addition and no new
  kit part went into it. Its recorded gap is interactivity: no drag-to-adjust.
  That gap is the design: the solver proposes, the person commits, and the
  commit is the four-eyes apply on the Worklist — so there is deliberately
  nothing to drag.

  The components, in demo order:

    * **Plan a week** (`:report`): runs `Run.plan_week/1` as the acting
      person — the demo's only plan request surface, browser-only, no
      console command. Its rows are the new run's candidates, each carrying
      the run's solve verdict (`solve_status`, `complete?`, `optimality`)
      beside the candidate's own fields. `week_start` defaults to next
      week's Monday, any day of the intended week is accepted.
    * **Shifts** (`:table` over the scheduling resource): the applied
      roster, earliest first, with the `state` filter — including the
      `:cancelled` rows a replan retired, which the gantt does not draw.
    * **Candidates** (`:table`): every proposal across runs, with its
      freshness and disposition. No actions here on purpose: approve or
      reject a candidate on the Worklist — the four-eyes sign-off is the
      approval UI, and this page never routes around it.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource ClinicDemo.Planning.Run
    surface_id "clinic_roster"
    title "Roster"
    record_label("run")

    diagram :roster_gantt do
      label "The week ahead"

      description "Next week's placed shifts per clinician; booked appointments no assignment covers, in red. Approve or reject a candidate on the Worklist."

      source ClinicDemo.Planning.RosterGantt
    end

    component :report, :plan_a_week do
      fields [
        :index,
        :check_status,
        :disposition,
        :freshness,
        :solve_status,
        :complete?,
        :optimality,
        :outcome_reason
      ]

      action :plan_week
      params [:week_start]
    end

    component :table, :shifts do
      resource ClinicDemo.Scheduling.Shift
      fields [:clinician_label, :role, :starts_at, :ends_at, :state]
      query :shifts
    end

    query :shifts do
      sortable [:starts_at, :ends_at]
      filters [:state]
      default_sort starts_at: :asc
      page_size 50
    end

    component :table, :candidates do
      resource ClinicDemo.Planning.Candidate
      fields [:index, :check_status, :freshness, :disposition, :run_id]

      query :candidates
    end

    query :candidates do
      sortable [:index]
      default_sort index: :asc
      page_size 25
    end
  end
end
