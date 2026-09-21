# Clinic Demo

A deliberately small Phoenix and Ash application, used to demonstrate
[`ash_agent_tools`](https://github.com/lukegalea/ash_agent_tools): a read-only
introspection layer that lets an AI agent read an Ash application's contract
instead of guessing at it.

The domain is a veterinary clinic's appointment book. Three resources, one
domain, about four hundred lines. That is the point — everything interesting
here is what the tooling can tell you about those four hundred lines without
you opening them.

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
`:cancel` — is its own named action with its own arguments, its own guard on
the prior status, and its own description. That is what makes the contract
worth reading: a caller that knows `:complete` exists still cannot use it
without knowing that it requires ten characters of clinical notes and refuses
an appointment that has not been checked in.

## Running it

Requires Elixir 1.17 or newer and a Postgres reachable at
`localhost:5432` as `postgres`/`postgres`. Override with the usual
`ClinicDemo.Repo` settings in `config/dev.exs` if yours differs.

```
mix setup           # deps, database, migrations, seed data, assets
mix phx.server      # http://localhost:4000
mix test            # 17 tests, all green
```

`mix setup` seeds two clinicians, three patients and three appointments, one
of which has been walked through check-in and completion so the data is not
all in the same state.

The `ash_agent_tools` dependency is declared `only: :dev, runtime: false`. It
is an introspection tool, never part of the running application.

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
  "domains": ["ClinicDemo.Scheduling"],
  "resources": [
    "ClinicDemo.Scheduling.Appointment",
    "ClinicDemo.Scheduling.Clinician",
    "ClinicDemo.Scheduling.Patient"
  ]
}
```

Discovery sees loaded modules. The Mix tasks compile and configure the
application first, so everything configured under `:ash_domains` is visible.

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
  "input": { "required": ["notes"], "optional": [], "private": [] },
  "arguments": [
    {
      "name": "notes",
      "type": "string",
      "description": "What was found and what was done.",
      "required?": true,
      "allow_nil?": false,
      "public?": true,
      "default": null,
      "source": {
        "file": ".../lib/clinic_demo/scheduling/appointment.ex",
        "line": 181
      }
    }
  ],
  "returns": { "kind": "record", "type": "Elixir.ClinicDemo.Scheduling.Appointment" }
}
```

Note `"accept": []`. Nothing on this action is settable as an attribute; the
only way in is the `notes` argument. An agent that greps for `def complete`
learns none of that. The `source` field is a file and line, so the next step
is a targeted read rather than a search.

Drop the action name to get the whole resource — fields with their types and
constraints, relationships with their destinations, and every action.

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
    "optional": [{ "name": "duration_minutes", "type": "integer" }]
  },
  "normalized_inputs": { "reason": "Hi", "duration_minutes": 3 }
}
```

Four distinct classes of mistake caught in one round trip: a malformed UUID, a
camelCased key with a spelling suggestion, two missing required inputs, and two
constraint violations. Nothing ran. No changeset was submitted, no action
fired, the database was not touched — `validate` builds the input with
`error?: false` and inspects it.

`normalized_inputs` shows the cast values, so `"3"` comes back as `3`.

### 4. Where does this name live?

```
mix ash_agent.search appoint --pretty
```

```json
{
  "query": "appoint",
  "count": 2,
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
and relationships on every loaded resource. `--kind attribute` narrows it.
This is the step that replaces "grep, get forty hits, read six files".

### 5. What is at this line?

```
mix ash_agent.context lib/clinic_demo/scheduling/appointment.ex:174 --pretty
```

```json
{
  "file": "lib/clinic_demo/scheduling/appointment.ex",
  "module": {
    "kind": "resource",
    "name": "ClinicDemo.Scheduling.Appointment",
    "domain": "Elixir.ClinicDemo.Scheduling"
  },
  "match": { "kind": "action", "name": "complete", "span": { "start_line": 174, "end_line": 192 } },
  "nearest": [
    { "kind": "action", "name": "complete", "line": 174, "distance": 0 },
    { "kind": "action", "name": "check_in", "line": 162, "distance": 1 },
    { "kind": "action", "name": "reschedule", "line": 144, "distance": 13 }
  ],
  "references": { "actions": [], "relationships": [], "code_interfaces": [] }
}
```

Point it at a compiler error, a diff hunk, or wherever the cursor landed. A
miss is graceful: you get `"match": null` and the nearest declarations, never
an error.

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
AshAgentTools.context("lib/clinic_demo/scheduling/appointment.ex", 174)
```

Same functions, same output, no boot.

## Known gaps

Found by using the tools on this application, and recorded in
`.agents/logs/tool-gaps.log`:

- `describe_action` reports an empty `code_interfaces` list for actions whose
  interfaces are declared on the domain rather than the resource. Ash 3.33
  stores those at `reference.definitions`; the tool reads `reference.define`.
  Every code interface in this demo is declared on the domain, which is the
  idiomatic placement, so the field is empty throughout.
- `describe_resource` lists attributes under `fields`. The aggregates and
  calculations declared on `Patient` and `Appointment` do not appear in the
  output.

## Layout

```
lib/clinic_demo/
  repo.ex                          AshPostgres repo
  scheduling.ex                    the domain and its code interface
  scheduling/
    patient.ex                     attributes, constraints, aggregates, calculations
    clinician.ex                   roster, with a conditional validation
    appointment.ex                 the lifecycle, and the only policies in the app
    calculations/age_in_days.ex    a module calculation
    validations/                   two custom validation modules, one atomic
priv/repo/
  migrations/                      generated by mix ash.codegen, never hand-written
  seeds.exs
test/clinic_demo/scheduling/       the lifecycle rules, asserted
```

## Licence

MIT.
