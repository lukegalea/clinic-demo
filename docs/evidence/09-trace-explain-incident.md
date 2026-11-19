# 09 — The planted incident: `trace.explain`, `explain_forbidden` and the event log

**Status: filled, locally.** Captured 2026-11-13 on this machine, against this
repository's tree with the CLIN-33 change on it. `ash_agent_tools` is pinned at
`0b7d9bc` (`mix.lock`); nothing was bumped for this. No CI run is cited: what
follows is a local run, and [the criteria below](#what-closes-which-criterion)
say so.

The claim: a fault planted on purpose, behind a switch, is found by an agent
using the three tools the storyline names — and the fix is observable. The
chapter that tells it is
[`docs/storyline.md`](../storyline.md#the-planted-incident-one-failed-booking-three-tools);
this file is the proof behind it.

## The pinned `Trace` API, checked before the walkthrough was written

`deps/ash_agent_tools` at `0b7d9bc`:

| Surface | What is there |
|---|---|
| `AshAgentTools.Trace.explain/2` (facade `AshAgentTools.explain_trace/2`) | Pure: a span list in, a budget-bounded report out — `root`, `errors` (innermost first), `policy`, `queries` (N+1 collapsed), `notifications`, `async`, `symbols`, `summary`, `truncated?`, `backend_url`. No ETS, no OpenTelemetry, no backend. |
| A source of spans | **None.** The module doc says "bring it spans from any source". |
| A Mix task for it | **None** (`ash_agent.*` has no `trace`). |
| An MCP daemon tool for it | **None** (`ash_forbidden` is there; no trace tool). |

So this repository supplies the missing half itself, and says so:
`ClinicDemo.Trace.capture/2` records the spans of one request (through the
global `ClinicDemo.Trace.Tracer`, registered as Ash's tracer), and
`bin/ash-agent trace` is a `mix run` wrapper in the same pattern as
`bin/ash-agent forbidden`. The two known gaps in the sibling `ash_enterprise`
tooling — `mix ash_enterprise.trace` stdout is not pure JSON, and `TraceSink`
starts after the endpoint so boot spans are dropped — are worked around by not
using it: `ash_enterprise` is not a dependency of this demo (`mix.lock` has no
entry), the capture is per request, and `mix clinic.incident`'s stdout is the
JSON alone once the project is compiled. Neither gap is fixed here, and neither
is exercised.

## Reproduce

The task writes to the database it points at — a veterinarian and a patient per
run, and the appointment on the healthy run — so point it at a scratch one. The
partition below is exactly that; `MIX_ENV=dev` with a fresh dev database works
the same (`ash_agent_tools` is a dev and test dependency).

```sh
export MIX_ENV=test MIX_TEST_PARTITION=incident
mix ash.setup --quiet
mix compile                       # so the task's stdout below is the JSON alone

# 1. The incident on: the documented request fails.
CLINIC_INCIDENT=triage_vet_only mix clinic.incident book > /tmp/book.json
jq '{incident, outcome, error: .error[0:60], event_log}' /tmp/book.json

# 2. trace.explain on the failing correlation id's spans.
bin/ash-agent trace < /tmp/book.json | jq '{errors: [.errors[] | {depth, name}], policy}'

# 3. explain_forbidden: what can deny record_triage.
bin/ash-agent forbidden ClinicDemo.Scheduling.Appointment record_triage \
  | jq '.policies[] | {description, condition, checks}'

# 4. The documented fix (the switch off): the same request succeeds.
mix clinic.incident book | jq '{incident, outcome, event_log}'

# The three acceptance tests, and the capture script that regenerates the transcripts:
MIX_ENV=test mix test test/clinic_demo/incident_test.exs
docs/evidence/bin/incident-capture.sh
```

`CLINIC_INCIDENT` may equally be set when starting the application
(`CLINIC_INCIDENT=triage_vet_only iex -S mix phx.server`), or flipped in a
running console with `ClinicDemo.Incident.enable!(:triage_vet_only)` and
`disable!/0`.

## What happened

### The symptom

A nurse at the front desk books a visit. Verbatim,
[`incident-1-book-failing.txt`](transcripts/incident-1-book-failing.txt) (the
`error` string is cut here; the transcript has all of it):

```
"outcome": "error",
"incident": "triage_vet_only",
"error": "could not start the visit process: %Ash.Error.Forbidden{bread_crumbs: [\"Error returned from: ClinicDemo.Scheduling.Appointment.record_triage\"], ...",
"event_log": [],
"span_count": 166
```

The error names the process engine; the policy that actually refused is not
named anywhere in it. The booking's own policy passed. A veterinarian's booking
fails identically (`incident_test.exs`: *the person booking is not the
problem*), which is what rules out the nurse's permissions.

### The event log is empty, and that is the finding

`"event_log": []` — the rows the request committed to the `ash_events` log.
Booking, decision evaluation and the failed write share one transaction, so
the rollback took them all. The healthy request, for comparison
([`incident-4-book-fixed.txt`](transcripts/incident-4-book-fixed.txt)):

```
"event_log": [
  "book on ClinicDemo.Scheduling.Appointment",
  "create on ClinicDemo.Decisions.Evaluation",
  "record_triage on ClinicDemo.Scheduling.Appointment",
  "record on ClinicDemo.Judgments.Observation",
  "materialise on ClinicDemo.Judgments.Fact"
]
```

Five rows against none: the log is the reference for what healthy looks like
and cannot say why this one failed. The only witness is the trace.

### `trace.explain` names the cause

[`incident-2-trace-explain.txt`](transcripts/incident-2-trace-explain.txt) is
`bin/ash-agent trace` over the 166 spans captured under correlation id
`0d679ade-88f8-48b3-b951-1b1936e04698`. Its `errors`, innermost first (depth,
name):

```
4  ash.policy ClinicDemo.Scheduling.Appointment.record_triage      forbidden
3  scheduling:appointment.record_triage                            forbidden
1  scheduling:appointment.book                                     could not start the visit process: ...
0  request book_appointment                                        could not start the visit process: ...
```

and its `policy` section, the answer:

```
"decision": "forbidden by: Triage is a veterinarian's judgement: only a veterinarian
may record it. (applies when action == :record_triage and the :triage_vet_only
incident is switched on) [actor ash_bpmn:advance]"
```

The policy, the action it sits on, the switch that makes it apply, and who was
refused: `ash_bpmn:advance`, the engine's system actor — not the nurse. The
report is about 2KB pretty-printed for a 166-span trace (`truncated?: false`).

### `explain_forbidden` shows where it lives

[`incident-3-explain-forbidden.txt`](transcripts/incident-3-explain-forbidden.txt)
lists every policy on the resource. The third:

```
"description": "Triage is a veterinarian's judgement: only a veterinarian may record it.",
"condition": ["action == :record_triage", "the :triage_vet_only incident is switched on"],
"checks": ["actor.role == :veterinarian"]
```

This tool lists what *can* deny; it says nothing about which policy did. The
trace did. Read together: the trace for the verdict, the listing for the policy
set around it.

### The fix

Switch off, same request ([`incident-4-book-fixed.txt`](transcripts/incident-4-book-fixed.txt)):
`"outcome": "ok"`, `"incident": null`, 270 spans, and `trace.explain` reports
`"errors": []` and `"policy": []`.

That is the documented fix: the incident ships as a rollback-able change, and
rolling it back is the fix. The durable fix, which the demo deliberately does
not apply, is to let the engine's actor through the policy while keeping it for
people. Checked in a scratch copy and then reverted: adding
`authorize_if <a check matching %AshBpmn.SystemActor{}>` ahead of the role
check made the incident-on booking succeed with triage recorded as `:urgent`,
and a nurse calling `record_triage` directly was still refused.
(`AshBpmn.Checks.AshBpmnInteraction`, the engine's own bypass check, does not
help here: `ClinicDemo.Visits.Invoker` calls the code interfaces with
`actor: ctx[:actor]` and not through `AshBpmn.Scope.engine/1`, so the context
flag it looks for is never set on these writes.)

## What closes which criterion

| Criterion | Test (`test/clinic_demo/incident_test.exs`) |
|---|---|
| `CLIN-33/AC-1` — incident on: the documented request fails with the planted symptom | `describe "CLIN-33/AC-1…"`: the booking is refused with the visit-process error; commits nothing; fails for a veterinarian too |
| `CLIN-33/AC-2` — `AshAgentTools.Trace.explain` on the failing correlation id names the planted cause | `describe "CLIN-33/AC-2…"`: `report.summary.trace_id` is the correlation id; `report.policy` is the one planted policy with its description, the incident and the actor; `report.errors` is the four-span chain |
| `CLIN-33/AC-3` — the documented fix applied: the request succeeds | `describe "CLIN-33/AC-3…"`: switch rolled back, the same request returns `{:ok, _}`, triage is `:urgent`, the trace has no errors and no policy entries |

Beyond the criteria: `explain_forbidden` lists the planted policy with its
conditions; a healthy booking writes the five event rows named above; the
switch ignores unknown values. The repository carries no `.sdlc/` directory and
no `@tag ac:` convention, so the ids ride in `describe` names, as
`UPD-EXTRACT-VERIFY/AC-1` does in `evidence_spike_test.exs`.

Full suite, `MIX_ENV=test mix test`, run locally on 2026-11-13 against a
scratch partition (`MIX_TEST_PARTITION=clin33`): see the pull request for the
tail. This is a local run — **not** CI evidence — and the criteria stay
`unverified` in the sense of the verification contract until the branch's CI
run reports them.

## Not captured

- A CI run for this branch (the pull request's checks are the oracle).
- A trace tool on the MCP daemon: the pinned daemon has none, so an agent on
  the daemon path would still shell out to `bin/ash-agent trace`.
- The durable policy fix, beyond the scratch check described above.
