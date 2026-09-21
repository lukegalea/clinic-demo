# Clinic Demo

Agents that work on codebases ask three questions — *what does this action
accept?*, *why was that forbidden?*, *where is this symbol?* — and this
repository answers all three from the way the application is actually built:
an Ash resource layer that declares its own contract and hands it to
[`ash_agent_tools`](https://github.com/lukegalea/ash_agent_tools), an Elixir
language server for everything that *is* a symbol, and two plain documents —
DMN and BPMN — for what the clinic decides and what it does. The domain is a
vet clinic's appointment book, kept deliberately small so that everything
interesting lives in the tooling and the documents rather than in more code.
[`docs/storyline.md`](docs/storyline.md) is the narrative and the
retrospective; the guided tour below is every claim made there, run against
this tree as checked out.

A deliberately small Phoenix and Ash application, used to demonstrate three
libraries that between them cover what an application knows, what it decides
and what it does:

| | |
|---|---|
| [`ash_agent_tools`](https://github.com/lukegalea/ash_agent_tools) | a read-only introspection layer, so an agent reads the contract instead of guessing at it |
| [`ash_decisions`](https://github.com/lukegalea/ash_decisions) | business rules as versioned DMN, evaluated rather than compiled in |
| [`ash_bpmn`](https://github.com/lukegalea/ash_bpmn) | a process as a BPMN document, executed as durable tokens over Postgres |

The domain is a veterinary clinic's appointment book. Three scheduling
resources, one DMN table, one BPMN diagram. That is the point — everything
interesting here is what the tooling can tell you, and what the two documents
do, without anybody writing another module.

## Why this exists

An agent working in an unfamiliar Elixir codebase does the same thing a new
hire does: it greps. It finds `def create`, guesses the shape of the params,
writes a call, and discovers what was wrong from the error message. In an Ash
application that is wasted effort, because the contract is already declared.
Every attribute has a type and constraints, every action has a list of
required and optional inputs, every relationship has a cardinality and a
destination, and all of it is introspectable at runtime.

`ash_agent_tools` exposes that as JSON on stdout. The agent asks a question
and gets an answer, rather than reading source and inferring one.

## The domain

`ClinicDemo.Scheduling` holds three resources:

| Resource | What it is |
|---|---|
| `Patient` | An animal on the books: species, breed, microchip, owner email, weight history. |
| `Clinician` | Someone who can be booked: a vet, a technician or a nurse. |
| `Appointment` | One patient, one clinician, one slot, and an explicit lifecycle. |

`Appointment` is the resource worth looking at. There is no generic `:update`
action. Each transition — `:book`, `:reschedule`, `:check_in`, `:complete`,
`:cancel`, `:record_triage`, `:mark_no_show`, `:discharge` — is its own named
action with its own arguments, its own guard on the prior status, and its own
description. That is what makes the contract worth reading: a caller that
knows `:complete` exists still cannot use it without knowing that it requires
ten characters of clinical notes and refuses an appointment that has not been
checked in.

Two documents sit beside those resources, and neither is Elixir:

| Document | What it is |
|---|---|
| `priv/decisions/appointment_triage.dmn` | How urgent a visit is, from severity, age band and species. Seven rules, FEEL input entries, `PRIORITY` hit policy. |
| `priv/processes/appointment_visit.bpmn` | The visit itself: booked, triaged, checked in, seen, sometimes waiting on a lab, discharged. |

### The one story the three layers tell

Booking an appointment starts a process instance. The instance's first node
asks the decision how urgent this is; the answer is promoted onto the token,
written onto the appointment by an ordinary Ash action, and read by a gateway
that routes the emergencies past an alert. Then the process waits — for the
animal to arrive, for the vet, and if bloods were sent, for the lab.

```
book_appointment/2
      │
      ▼
  Start_booked ─▶ Triage ─▶ RecordUrgency ─▶ HowUrgent ─┬─▶ AlertEmergencyTeam ─┐
                    │            │                      │                       │
        appointment.triage   :record_triage        routing.urgency              │
             (DMN)             (Ash action)          = "emergency"              │
                                                                                ▼
   End_no_show ◀─ MarkNoShow ◀─┬─ Arrived ◀─ CheckIn ◀───────────────────────────┘
                               │                 ▲ waits on a nurse
                          task.outcome
                            = "arrived"
                               │
                               ▼
                         MarkCheckedIn ─▶ Consult ─▶ LabsPending ─┬─▶ AwaitLabResults ─┐
                                             ▲ waits on the vet   │    ▲ waits on the  │
                                                                  │      lab           │
                                                                  ▼                    ▼
                                                              Discharge ◀──────────────┘
                                                                  │  :discharge
                                                                  ▼
                                                            End_discharged
```

Three rules hold the whole thing together, and each belongs to one of the
packages:

- **A decision decides.** It never acts. `appointment.triage` returns the
  string `"emergency"`; `Appointment.:record_triage` is what writes it down.
- **The graph orchestrates.** It never decides. The diagram carries a decision
  *reference* — no thresholds, no species list — and the gateway after it tests
  `routing.urgency`, a signal, not a rule.
- **The Ash action is the only way anything changes.** `:discharge` refuses a
  visit that has not been written up, and refuses the process engine too. There
  is a test for exactly that.

## Running it

Requires Elixir 1.17 or newer and a Postgres reachable at
`localhost:5432` as `postgres`/`postgres`. Override with the usual
`ClinicDemo.Repo` settings in `config/dev.exs` if yours differs.

`xmllint` must also be on `PATH` (the `libxml2` package). The DMN engine
validates every document against the normative XSD by shelling out to it;
without it, every model fails to load with `:schema_validator_unavailable`.

```
mix setup           # deps, database, migrations, seed data, assets
mix phx.server      # http://localhost:4000
mix test            # 43 tests, all green
```

`mix setup` publishes the two rule documents, then seeds three clinicians,
three patients and three appointments. Booking each one starts a visit
process, and the seeds walk two of them along, so the database ends up with an
instance parked on the lab wait rather than three rows in the same state:

```
Published:
  appointment.triage v1 (published)
  appointment_visit v1 (published)

Seeded:
  3 clinicians
  3 patients
  3 appointments
  3 visit instances
  2 work items waiting: AwaitLabResults, CheckIn

Triage decided:
  Limping on the right foreleg since Saturday -> urgent
  Annual vaccination -> routine
  Off her food and quieter than usual -> emergency
```

The `ash_agent_tools` dependency is declared `only: :dev, runtime: false`. It
is an introspection tool, never part of the running application.
`ash_decisions` and `ash_bpmn` are not: they are the application.

## Two servers, and which one to ask

The repository is wired for two MCP servers, because an agent asks two kinds
of question and neither tool answers the other's.

[Serena](https://github.com/oraios/serena), over an Elixir language server,
handles symbols: where is this function, who calls it, rename it everywhere.
`ash_agent_tools` handles declarations: what does this action accept, what
are this attribute's constraints, what could forbid this call. It reaches an
agent two ways, with the same JSON on both: as an MCP daemon
(`mix ash_agent.serve` on `127.0.0.1:4100`, registered live in `.mcp.json`
and `opencode.json` — boot the Mix process once, and every call afterwards is
a millisecond read), or via `bin/ash-agent` in a shell, which pays a Mix boot
per call and is what a CI job or a person uses.

The boundary is structural rather than a matter of taste. `find_symbol` for
`complete` returns nothing, because there is no symbol called `complete` —
there is an `update :complete do` block, which is data in a DSL that the
compiler turns into introspectable state. A language server reads Elixir; it
does not read Ash.

Serena's Elixir backend *is* Expert, so this repository drives it with a build
of the fork carrying the `documentSymbol` crash fix rather than the release
Serena would download. Two things that look like hangs and are not: Serena
answers from `_build`, so the project must be compiled first, and cross-file
answers need about ten seconds of indexing after that.

`docs/agents.md` has the setup, the expected waits, a walkthrough of all
three tools, and the GPL boundary the Serena integration is kept inside.

## Guided tour

Every command below runs against this repository as checked out. Output is
JSON on stdout; `--pretty` is for humans, and `--out FILE` writes to a file
instead. The first invocation pays a Mix boot of ten to fifteen seconds, so
batch your questions.

### 1. What is here?

```
mix ash_agent.describe --pretty
```

```json
{
  "domains": [
    "ClinicDemo.Decisions",
    "ClinicDemo.Scheduling",
    "ClinicDemo.Visits"
  ],
  "resources": [
    "ClinicDemo.Decisions.Definition",
    "ClinicDemo.Decisions.Evaluation",
    "ClinicDemo.Scheduling.Appointment",
    "ClinicDemo.Scheduling.Clinician",
    "ClinicDemo.Scheduling.Patient",
    "ClinicDemo.Visits.Definition",
    "ClinicDemo.Visits.HumanTask",
    "ClinicDemo.Visits.Instance",
    "ClinicDemo.Visits.ProcessEvent",
    "ClinicDemo.Visits.TaskCandidate",
    "ClinicDemo.Visits.Token"
  ]
}
```

Discovery sees loaded modules. The Mix tasks compile and configure the
application first, so everything configured under `:ash_domains` is visible.
Eight of those eleven resources are generated by the two rule packages — the
demo declares a repo, a table name and a policy set for each, and nothing
else. They are ordinary Ash resources, which is why they turn up here at all.

### 2. What is the contract for one action?

```
mix ash_agent.describe ClinicDemo.Scheduling.Appointment complete --pretty
```

```json
{
  "name": "complete",
  "type": "update",
  "description": "The visit happened. Clinical notes are mandatory.",
  "accept": [],
  "input": {
    "required": ["notes"],
    "optional": [],
    "private": [],
    "arguments": [
      {
        "name": "notes",
        "type": "string",
        "description": "What was found and what was done.",
        "required?": true,
        "allow_nil?": false,
        "public?": true,
        "default": null,
        "constraints": {
          "min_length": 10, "max_length": 4000, "trim?": true, "allow_empty?": false
        },
        "source": {
          "file": ".../lib/clinic_demo/scheduling/appointment.ex",
          "line": 215
        }
      }
    ]
  },
  "returns": { "kind": "record", "type": "Elixir.ClinicDemo.Scheduling.Appointment" },
  "code_interfaces": [
    { "name": "complete_appointment", "domain": "Elixir.ClinicDemo.Scheduling",
      "args": ["notes"], "get?": false, "on_resource?": false }
  ]
}
```

Note `"accept": []`. Nothing on this action is settable as an attribute; the
only way in is the `notes` argument — and its `constraints` are in the
contract itself: ten characters of clinical notes, at most 4000, trimmed. An
agent that greps for `def complete` learns none of that. The `source` field
is a file and line, so the next step is a targeted read rather than a search.

Drop the action name to get the whole resource — fields with their types and
constraints, the aggregates and calculations, relationships with their
destinations, and every action.

### 3. Will my call work, before I make it?

```
mix ash_agent.validate ClinicDemo.Scheduling.Appointment book \
  '{"reason":"Hi","duration_minutes":"3","patient_id":"not-a-uuid","clinicianId":"x"}' --pretty
```

```json
{
  "valid?": false,
  "action": "book",
  "action_type": "create",
  "errors": [
    { "path": "patient_id", "message": "is invalid" },
    {
      "path": "clinicianId",
      "message": "unknown input \"clinicianId\" for action :book; ...",
      "did_you_mean": ["clinician_id"]
    },
    { "path": "clinician_id", "message": "is required" },
    { "path": "scheduled_at", "message": "is required" },
    { "message": "Invalid value provided for reason: length must be greater than or equal to 3." },
    { "message": "Invalid value provided for duration_minutes: must be greater than or equal to 5." }
  ],
  "expected": {
    "required": ["patient_id", "clinician_id", "scheduled_at", "reason"],
    "optional": [
      { "name": "duration_minutes", "type": "integer",
        "constraints": { "min": 5, "max": 240 } },
      { "name": "severity", "type": "integer",
        "constraints": { "min": 1, "max": 5 } }
    ]
  },
  "normalized_inputs": { "reason": "Hi", "duration_minutes": 3 }
}
```

Four distinct classes of mistake caught in one round trip: a malformed UUID, a
camelCased key with a spelling suggestion, two missing required inputs, and two
constraint violations. Nothing ran. No changeset was submitted, no action
fired, the database was not touched — `validate` builds the input with
`error?: false` and inspects it. The `expected` block carries the optional
inputs' constraints, so the five-minute floor on `duration_minutes` is
readable before the call, not learned from the error.

`normalized_inputs` shows the cast values, so `"3"` comes back as `3`.

### 4. Where does this name live?

```
mix ash_agent.search appoint --pretty
```

```json
{
  "query": "appoint",
  "count": 2,
  "kinds": null,
  "results": [
    {
      "name": "appointments",
      "kind": "relationship",
      "type": "has_many",
      "resource": "Elixir.ClinicDemo.Scheduling.Clinician",
      "source": { "file": ".../clinician.ex", "line": 53 }
    },
    {
      "name": "appointments",
      "kind": "relationship",
      "type": "has_many",
      "resource": "Elixir.ClinicDemo.Scheduling.Patient",
      "source": { "file": ".../patient.ex", "line": 73 }
    }
  ]
}
```

Substring match, case-insensitive, across attributes, actions, calculations
and relationships on every loaded resource. `--kind attribute` narrows it
(and then `"kinds"` echoes the restriction back).
This is the step that replaces "grep, get forty hits, read six files".

### 5. What is at this line?

```
mix ash_agent.context lib/clinic_demo/scheduling/appointment.ex:208 --pretty
```

```json
{
  "file": "lib/clinic_demo/scheduling/appointment.ex",
  "line": 208,
  "module": {
    "kind": "resource",
    "name": "ClinicDemo.Scheduling.Appointment",
    "domain": "Elixir.ClinicDemo.Scheduling"
  },
  "match": { "kind": "action", "name": "complete", "span": { "start_line": 208, "end_line": 226 } },
  "nearest": [
    { "kind": "relationship", "name": "clinician", "line": 110, "distance": 0 },
    { "kind": "action", "name": "complete", "line": 208, "distance": 0 },
    { "kind": "action", "name": "check_in", "line": 196, "distance": 1 },
    { "kind": "action", "name": "reschedule", "line": 178, "distance": 13 },
    { "kind": "action", "name": "cancel", "line": 227, "distance": 19 }
  ],
  "references": {
    "actions": [],
    "relationships": [],
    "code_interfaces": [
      { "name": "complete_appointment", "domain": "Elixir.ClinicDemo.Scheduling",
        "args": ["notes"], "get?": false, "on_resource?": false }
    ]
  }
}
```

Point it at a compiler error, a diff hunk, or wherever the cursor landed.
The `references` block answers "who calls into this?" at the Ash level — the
domain's `complete_appointment` code interface names `:complete` among its
args — which is the question `grep "complete"` drowns in. A miss is graceful:
you get `"match": null` and the nearest declarations, never an error.

### 6. What did the rule decide, and why is that the only place it lives?

The triage table is `priv/decisions/appointment_triage.dmn`. Seven rules, three
typed columns, FEEL in the input entries:

| Presenting severity | Age band | Species | Urgency |
|---|---|---|---|
| `>= 4` | `-` | `-` | `"emergency"` |
| `>= 3` | `"neonate", "senior"` | `-` | `"emergency"` |
| `>= 3` | `-` | `"rabbit", "ferret", "bird", "reptile"` | `"emergency"` |
| `[2..3]` | `-` | `-` | `"urgent"` |
| `< 2` | `"neonate", "senior"` | `-` | `"soon"` |
| `< 2` | `-` | `"rabbit", "ferret", "bird", "reptile"` | `"soon"` |
| `-` | `-` | `-` | `"routine"` |

The hit policy is `PRIORITY`, so the overlaps are the design rather than a
defect: a severity-3 senior rabbit matches four rules, and the most urgent
answer wins by the order declared in the output's `outputValues`, not by where
a rule sits in the document. The last row is the catch-all, which is why the
table has no gap.

Ask it directly — this is the same seam the process uses:

```elixir
ClinicDemo.Decisions.Resolver.decide(
  "appointment.triage",
  %{"severity" => 3, "ageBand" => "adult", "species" => "rabbit"},
  %{}
)
#=> {:ok, %{version: 1, outputs: %{"urgency" => "emergency"}}}

ClinicDemo.Decisions.Resolver.decide(
  "appointment.triage",
  %{"severity" => 3, "ageBand" => "adult", "species" => "dog"},
  %{}
)
#=> {:ok, %{version: 1, outputs: %{"urgency" => "urgent"}}}
```

Same severity, different animal, different answer, and no Elixir anywhere in
between. Every call also writes an `Evaluation` row — inputs, outputs, the
version that decided, the microseconds it took — because "which version of
which rule decided this case" is a question somebody eventually asks.

Now look at the action that writes the answer down:

```
mix ash_agent.describe ClinicDemo.Scheduling.Appointment record_triage --pretty
```

```json
{
  "name": "record_triage",
  "type": "update",
  "description": "Write down how urgent the triage decision said this is.\n\nThe decision decides; this action acts. ...",
  "accept": [],
  "input": { "required": ["urgency"], "optional": [], "private": [] },
  "arguments": [
    {
      "name": "urgency",
      "type": "atom",
      "description": "The decision's answer, not the caller's opinion.",
      "required?": true,
      "allow_nil?": false,
      "public?": true,
      "default": null,
      "source": {
        "file": ".../lib/clinic_demo/scheduling/appointment.ex",
        "line": 259
      }
    }
  ],
  "returns": { "kind": "record", "type": "Elixir.ClinicDemo.Scheduling.Appointment" }
}
```

`"accept": []` again. There is no way to set `triage_urgency` as an attribute,
which is the structural half of "a decision decides and the caller acts": the
only input is an argument named for whose answer it is.

### 7. Publishing refuses a process that references a rule nobody wrote

Order matters, and the tooling enforces it rather than documenting it. Point
the diagram's business rule task at a decision that does not exist:

```elixir
xml = String.replace(bpmn, ~s(ref="appointment.triage"), ~s(ref="appointment.triage_v2"))
draft = ClinicDemo.Visits.create_process!(%{key: "scratch", name: "Scratch", xml: xml}, actor: actor)

draft.errors
#=> [
#=>   %{
#=>     "message" => "businessRuleTask 'Triage' references decision 'appointment.triage_v2', which does not exist",
#=>     "path" => "Triage"
#=>   }
#=> ]

ClinicDemo.Visits.publish_process(draft, actor: actor)
#=> {:error, ...}
```

The compiler asked `ClinicDemo.Decisions.Resolver.exists?/1` at publish time.
Without that, the diagram would ship and fail at three in the morning on the
first instance that reached the node. `ClinicDemo.Rules.install!/0` publishes
the decision first for exactly this reason.

### 8. Book an appointment and watch the token move

```elixir
appointment = ClinicDemo.Scheduling.book_appointment!(%{
  patient_id: biscuit.id, clinician_id: vet.id,
  scheduled_at: tomorrow, reason: "Limping on the right foreleg", severity: 2
}, actor: staff)
```

That one call started an instance. `AshBpmn.instance_report/2` on it:

```
appointment: Biscuit (dog) severity 2 -> urgent

tokens:
  Start_booked       consumed
  Triage             consumed
  RecordUrgency      consumed
  HowUrgent          consumed
  CheckIn            waiting

events:
  instance_started
  node_entered         Start_booked
  node_completed       Triage
  decision_evaluated   Triage      %{"decision_ref" => "appointment.triage",
                                     "inputs" => %{"ageBand" => "adult", "severity" => "2", "species" => "dog"},
                                     "promoted" => %{"urgency" => "urgent"}}
  node_completed       RecordUrgency
  action_invoked       RecordUrgency
  gateway_branch_taken HowUrgent
  task_created         CheckIn
```

Read the `decision_evaluated` row: it names the decision, the inputs it was
given, and the one scalar promoted onto the token. Not the whole result — the
decision layer keeps that, and two logs that can disagree are worse than one.

Note `"severity" => "2"`. FEEL numbers are decimal, and every value crossing
into the engine goes through `to_feel_value/2` first. Skip that and `>= 4`
becomes a type error, which is `null`, which a decision table reads as "no
rule matched" — a silently empty table with nothing reported anywhere.

### 9. The wait state

The third animal in the seeds is a rabbit whose vet sent bloods. Its instance
is parked:

```
Clover (rabbit), severity 3 -> emergency
appointment completed, discharged_at nil
instance    running

tokens:
  Start_booked       consumed
  Triage             consumed
  RecordUrgency      consumed
  HowUrgent          consumed
  AlertEmergencyTeam consumed
  CheckIn            consumed
  Arrived            consumed
  MarkCheckedIn      consumed
  Consult            consumed
  LabsPending        consumed
  AwaitLabResults    waiting

waiting on: Await lab results  (AwaitLabResults, open)
```

Eleven tokens, ten consumed, one waiting. Nothing is polling and no process is
held open — the wait is a row with `status = waiting`, and it will still be
there after a deploy. The task carries an escalate timer at four hours, which
is what a clinic actually wants from a wait: a nudge, not a stuck row nobody
notices.

Completing it as somebody in the lab finishes the visit:

```elixir
AshBpmn.complete_task(lab_task, outcome: :results_in, actor: %{id: technician.id})
```

…and the `Discharge` node runs `:discharge`, which refuses any appointment
that is not `:completed`. That guard applies to the engine exactly as it
applies to a person, and
`test/clinic_demo/visits/appointment_visit_test.exs` asserts it: reach
`Discharge` on a visit nobody wrote up and the node fails rather than closing
it.

### 10. Judge the change before you claim it is done

`mix ash_agent.laws` checks source against the codified 26 Iron Laws. It is
pure text processing — no boot, not even a compile — and it reports violations
only, at three certainty tiers.

```
mix ash_agent.laws lib/clinic_demo/visits/invoker.ex lib/clinic_demo/rules.ex \
  --min-tier review --pretty
```

```json
{
  "sources": [
    {
      "source": "lib/clinic_demo/visits/invoker.ex",
      "clean?": true,
      "counts": { "definite": 0, "likely": 0, "review": 0 },
      "laws_checked": 26,
      "laws_without_detectors": [
        { "id": "18", "name": "changeset-errors-before-ui-debugging" },
        { "id": "06", "name": "has-many-queries-belongs-to-joins" },
        "... (seven behavioural laws in total, listed so nobody assumes full coverage)"
      ],
      "violations": []
    },
    {
      "source": "lib/clinic_demo/rules.ex",
      "clean?": false,
      "counts": { "definite": 0, "likely": 0, "review": 1 },
      "laws_checked": 26,
      "laws_without_detectors": [ "..." ],
      "violations": [
        {
          "law": "16",
          "name": "external-resource-for-compile-time-files",
          "category": "elixir",
          "tier": "review",
          "line": 139,
          "text": "defp read!(path), do: :clinic_demo |> Application.app_dir(path) |> File.read!()",
          "hint": "File.read! with no @external_resource in the module: edits to the read file will not trigger recompilation — declare the path with @external_resource"
        }
      ]
    }
  ],
  "clean?": false,
  "counts": { "definite": 0, "likely": 0, "review": 1 }
}
```

That one is a `review`-tier hit and this project declines it, on the record in
`usage-rules.md`: the DMN and BPMN documents are read at runtime *because* the
whole reason a rule lives outside code is that changing it should not need a
recompile. The judge is a pattern matcher, not an oracle — its value is that
the disagreement is now written down instead of re-argued.

For a change rather than a file, feed it a diff and only added lines are
judged:

```
git diff main | mix ash_agent.laws - --diff
```

### Also available

- `mix ash_agent.edit replace ClinicDemo.Scheduling.Clinician/attributes/active --body '...'`
  — a semantic DSL edit addressed by name path rather than line range, dry-run
  by default, printing a diff and a digest you pass back with `--write` to
  guard against a concurrent change.
- `mix ash_agent.runtime snapshot|top|tree` — read-only BEAM introspection.
- `mix ash_agent.gaps` — the digest of questions the tools could not answer.
  A fresh Mix boot reports none; the aggregate lives in the VM where
  `AshAgentTools.Kaizen.attach/0` was called.

## Prefer in-VM calls

Each Mix task pays a boot. If you already have a node running the application
— `iex -S mix phx.server`, Livebook, or a `project_eval`-style tool — call the
library directly and skip it entirely:

```elixir
AshAgentTools.eval_docs()
AshAgentTools.describe_action(ClinicDemo.Scheduling.Appointment, :complete)
AshAgentTools.validate_input(ClinicDemo.Scheduling.Appointment, :book, %{"reason" => "Hi"})
AshAgentTools.context("lib/clinic_demo/scheduling/appointment.ex", 208)
AshAgentTools.judge_laws(File.read!("lib/clinic_demo/rules.ex"), min_tier: :review)
```

Same functions, same output, no boot.

## Known gaps

Found by using these packages on this application, and recorded with dates in
`.agents/logs/tool-gaps.log`. They are here rather than quietly worked around
because the log is the input to the next round of tool work, and a demo that
hid them would be a worse demo.

### ash_agent_tools

Found here by dogfooding, logged, and since **fixed upstream** — this
repository pins `688fad7`, which carries the fixes, so the tour above shows
the post-fix behavior:

- `describe_action` used to report an empty `code_interfaces` list for
  actions whose interfaces are declared on the domain rather than the
  resource (Ash 3.33 stores those at `reference.definitions`; the tool read
  `reference.define`). Every code interface in this demo is declared on the
  domain — the idiomatic placement — so the field was empty throughout.
  Now populated, with an `on_resource?` marker; `context` reports them too
  (tour step 5).
- `describe_resource` used to list attributes under `fields` only; the
  aggregates and calculations declared on `Patient` and `Appointment` did
  not appear anywhere. Now they are first-class blocks in the output.
- An action **argument** used to carry no `constraints`, though an attribute
  did — an agent could only find the four valid `urgency` atoms by sending a
  fifth and reading `"is invalid"`. Now arguments carry constraints, and
  `validate`'s `expected` block shows them for optional inputs (tour
  step 3).

The gap log keeps the dated record of all of it, including the one
`ash_agent_tools` question the Mix-task surface still cannot ask: there is
no Mix task for `explain_forbidden/2` (`bin/ash-agent` works around it with
`mix run`; the MCP daemon exposes `ash_forbidden` as an ordinary tool).

### ash_bpmn

- **A BPMN document containing any non-ASCII character fails to parse.**
  `AshBpmn.Compiler.Xml.parse/1` hands `:xmerl_scan.string/2` codepoints
  (`:unicode.characters_to_list/1`), and xmerl does its own decoding and wants
  raw octets, so it rejects everything above 127 as an illegal character — in
  a document that declares UTF-8. An em dash in a comment is enough. This demo
  keeps `appointment_visit.bpmn` ASCII-only as a result. `ash_decisions` hit
  the same thing and fixed it in `AshDecisions.Tck.Xml.parse/1`, with a comment
  explaining exactly this, so the fix exists in a sibling package and has not
  travelled.
- **A completed human task cannot be read back.**
  `AshBpmn.Resources.HumanTask` declares `attribute :outcome, :atom` with no
  `constraints one_of:`, so the Ecto type is
  `Ash.Type.Atom.EctoType<[unsafe_to_atom?: false]>`. Writing stores the atom
  as a string; reading refuses to turn it back, because without a `one_of`
  list there is nothing safe to match against. Any query that touches a
  completed task raises `cannot load "arrived" as type ...`, and that takes
  `AshBpmn.instance_report/2` with it — so the report in tour step 8 works
  only for an instance that has not completed a human task yet, and step 9
  reads the token rows directly instead. Reproduced on ash 3.33.8.

### ash_decisions

- **There is no publish-time verification in the published package, and the
  README says there is.** `AshDecisions.Verifier` — the overlap, completeness
  and unreachable-rule analysis — is not on `origin/main`; the only Mix tasks
  the package ships are `ash_decisions.tck` and `ash_decisions.tck.verify`,
  and both run the DMN conformance corpus rather than your tables. What does
  gate publication is the compiler: `create` records refused constructs and
  dangling references in `errors`, and `publish` refuses over a non-empty
  `errors` list. That is real and this demo relies on it — it is what step 7
  shows — but the overlaps in the triage table have been reasoned about by
  hand rather than proved by a tool.

## Layout

```
usage-rules.md                     this project's conventions, in the form a
                                   dependency ships them
docs/storyline.md                  the public narrative, and the retrospective
docs/agents.md                     the two-server agent wiring, and its waits
docs/evidence/                     captured transcripts for every claim above
bin/ash-agent                      ash_agent_tools as one command
mix ash_agent.serve                ash_agent_tools as an MCP daemon, port 4100
bin/serena-mcp                     Serena, pointed at our Expert build
bin/expert-smoke.exs               a hand-written LSP conversation, to prove it
.mcp.json .serena/project.yml      the wiring itself, for Claude Code and Serena
opencode.json
lib/clinic_demo/
  repo.ex                          AshPostgres repo
  rules.ex                         publishes both documents from priv/, in order
  scheduling.ex                    the domain and its code interface
  scheduling/
    patient.ex                     attributes, constraints, aggregates, calculations
    clinician.ex                   roster, with a conditional validation
    appointment.ex                 the lifecycle, and the only policies in the app
    calculations/age_in_days.ex    a module calculation
    calculations/age_band.ex       one of the triage decision's three inputs
    changes/start_visit_process.ex the one line joining booking to the process
    validations/                   two custom validation modules, one atomic
  decisions.ex                     the DMN domain
  decisions/
    definition.ex                  versioned DMN documents
    evaluation.ex                  what each invoked decision saw and decided
    resolver.ex                    the bridge: ash_bpmn asks, ash_decisions answers
  visits.ex                        the BPMN domain
  visits/
    definition.ex instance.ex token.ex
    human_task.ex task_candidate.ex process_event.ex
    roster.ex                      who a task is for, from the Clinician table
    invoker.ex                     what a service task does: Scheduling calls
priv/
  decisions/appointment_triage.dmn the triage table
  processes/appointment_visit.bpmn the visit process
  repo/migrations/                 generated by mix ash.codegen, never hand-written
  repo/seeds.exs
test/clinic_demo/
  scheduling/                      the lifecycle rules, asserted
  decisions/triage_test.exs        what the table answers, case by case
  visits/appointment_visit_test.exs the happy path, the wait, the refusal
```

## Licence

MIT.
