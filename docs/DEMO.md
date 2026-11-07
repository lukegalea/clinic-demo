# Clinic demo — the roster loop

Presenter-oriented: everything here is browser-only against the deployed app.
All data is synthetic (the seed walks a fictional clinic day; the planning
models describe no real practice).

## Setup (once, engineer)

1. The deploy + seed per `docs/FLY.md` §5 and §"Seeding (the proven
   procedure)". After the release is live and the seed's terminal line
   (`Value projection: folded N remaining value events`) has printed, the app
   is demo-able: the planning models are published and bound, the shift
   patterns and the mobile places/matrix exist, and the seed walked a day of
   appointments.
2. Hand out the URL and the gate password (`DEMO_GATE_PASSWORD`).

## The demo script

1. **Gate** → any deep link (`/roster`) lands on the shared sign-in; the
   password lets everyone in.

2. **`/roster` first, empty.** "The week ahead" shows the gantt with no bars —
   nothing is planned yet — and the Shifts and Candidates lists are empty.
   This is the honest starting point: the roster is what planning + approval
   *produce*, not an input.

3. **`/schedule` — the demand side.** The week's booked appointments: the
   patients, the reasons, the triage answers. These are what the roster must
   cover.

4. **Back on `/roster`: "Plan a week".** The report runs the weekly-roster
   model as the acting clinician (a real MiniZinc solve, seconds on the seeded
   week). The rows are the run's candidates, best first: `check_status`
   `correct` means both the MiniZinc solution checker AND the independent
   validator accepted it; `solve_status` `optimal` with `complete?` true means
   the solver proved the objective; `disposition` `proposed` — a proposal,
   never an applied fact. Uncovered appointments surface honestly (a `:needs_input`
   run names its gaps instead of inventing coverage).

5. **`/acting-as` → the clinic manager → `/worklist`**: the plan request opened
   the four-eyes process; complete **Clinic manager sign-off** (approve). Then
   `/acting-as` → the head vet → complete **Head vet sign-off**. The second
   signature is what applies the candidate: the Shift and Assignment rows are
   written in the apply's own transaction, and a re-check of every input the
   plan read guards it — drift refuses the apply.

6. **`/roster` again.** The gantt redraws: one section per clinician with the
   week's shift bars, and the **Uncovered appointments** section — booked
   visits no assignment covers, in red — now empty or smaller. The Shifts
   list matches the bars.

7. **Optional — the mobile variant**: the mobile-visit planning loop
   (travel matrix, route proposals, four-eyes apply) is scripted in the test
   suite (`test/clinic_demo/planning/mobile_visits_test.exs`,
   `mobile_exits_test.exs`); the demo above uses the weekly roster only.

## The gold-standard note

The gantt IS the industry shape — per-person timeline rows plus a coverage
band (cf. Kronos/UKG, Odoo Planning, Timefold) — delivered through the UI
kit's existing live-diagram part (mermaid), with no new kit work. The
recorded gap is interactivity: no drag-to-adjust. That gap is deliberate: the
solver proposes, the person commits, and the commit is the four-eyes apply —
the thing you can't drag is the thing that keeps the state machine honest.

## Known flaky tests

Two tests are quarantined (pointer comments on the files; they do not gate
deploys):

* `test/clinic_demo_web/a2ui/as_of_surface_test.exs` — async temporal re-open
  race on the appointment's period.
* `test/clinic_demo_web/live/revenue_live_test.exs` — date-boundary flake on
  days 1–9 of a month.

## Reset

`docs/FLY.md` §7 (reset procedures) — drop and re-seed; then re-run the seed
procedure. Every seed is idempotent: models re-bind, templates and places are
lookup-or-create, the appointment walk resumes cleanly.
