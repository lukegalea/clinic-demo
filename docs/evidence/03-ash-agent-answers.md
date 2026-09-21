# 03 — `ash_agent` answers: describe, validate, forbidden

Three questions an agent actually asks before calling into the domain, each
answered by `bin/ash-agent` with JSON on stdout. All transcripts captured
2026-09-21 against the tree as checked out.

## describe — the contract before the call

```
$ bin/ash-agent describe ClinicDemo.Scheduling.Appointment book --pretty
{
  "input": {
    "private": [],
    "required": [
      "patient_id",
      "clinician_id",
      "scheduled_at",
      "reason"
    ],
    "optional": [
      {
        "name": "duration_minutes",
        "type": "integer"
      },
      {
        "name": "severity",
        "type": "integer"
      }
    ]
  },
  "name": "book",
  "type": "create",
  "accept": [
    "scheduled_at",
    "duration_minutes",
    "reason",
    "severity"
  ],
  "description": "Put a new appointment on the schedule.",
  "arguments": [
    {
      "default": null,
      "name": "patient_id",
      "type": "uuid",
      "description": "An existing patient. Booking does not create one.",
      "source": {
        "line": 157,
        "file": "/home/lukegalea/capstone-demo/lib/clinic_demo/scheduling/appointment.ex"
      },
      "required?": true,
      "public?": true,
      "allow_nil?": false
    },
    {
      "default": null,
      "name": "clinician_id",
      "type": "uuid",
      "description": "An existing, active clinician.",
      ... (same shape, line 162)
    }
  ],
  "resource": "Elixir.ClinicDemo.Scheduling.Appointment",
  "source": { "line": 152, "file": ".../lib/clinic_demo/scheduling/appointment.ex" },
  "returns": { "type": "Elixir.ClinicDemo.Scheduling.Appointment", "kind": "record" },
  "code_interfaces": []
}
```

Full transcript: [`transcripts/ash-agent-describe-book.txt`](transcripts/ash-agent-describe-book.txt).
Four required inputs, two optional, each argument with a type, a one-line
description, and the file and line that declares it. The `code_interfaces`
field is empty for the reason recorded in `docs/agents.md` and the gap log:
the interfaces are declared on the domain, and the tool reads the resource's
references only.

## validate — four mistakes, one round trip, nothing run

The documented bad-params call, verbatim:

```
$ bin/ash-agent validate ClinicDemo.Scheduling.Appointment book \
    '{"reason":"Hi","duration_minutes":"3","patient_id":"not-a-uuid","clinicianId":"x"}' --pretty
{
  "resource": "Elixir.ClinicDemo.Scheduling.Appointment",
  "errors": [
    {
      "message": "is invalid",
      "path": "patient_id",
      "source": { "line": 157, "file": ".../lib/clinic_demo/scheduling/appointment.ex" }
    },
    {
      "message": "unknown input \"clinicianId\" for action :book; Ash says: No such attribute on
ClinicDemo.Scheduling.Appointment, or argument on ClinicDemo.Scheduling.Appointment.book | Did you mean: | * clinician_id | ...",
      "path": "clinicianId",
      "source": null,
      "did_you_mean": [
        "clinician_id"
      ]
    },
    {
      "message": "is required",
      "path": "clinician_id",
      "source": null,
      "did_you_mean": null
    },
    {
      "message": "is required",
      "path": "scheduled_at",
      "source": null,
      "did_you_mean": null
    },
    {
      "message": "Invalid value provided for reason: length must be greater than or equal to 3.\n\nValue: \"Hi\"\n",
      "path": null,
      ...
    }
  ],
  "normalized_inputs": {
    "reason": "Hi",
    "duration_minutes": 3
  },
  ... (action, action_type, expected blocks)
}
```

Full transcript: [`transcripts/ash-agent-validate-book-bad-params.txt`](transcripts/ash-agent-validate-book-bad-params.txt).
Four classes of mistake in one response: a malformed UUID (`"not-a-uuid"`,
caught at the attribute's declared type), a camelCased key that comes back
with a `did_you_mean` spelling suggestion, two missing required inputs, and a
constraint violation (`"Hi"` is shorter than the declared minimum of 3). And
`normalized_inputs` shows the casts that *did* succeed — `"3"` came back as
the integer `3`. Nothing ran: no changeset was submitted, no action fired, the
database was not touched. `validate` builds the input with `error?: false` and
inspects it.

## forbidden — the policies that can deny, not a verdict

```
$ bin/ash-agent forbidden ClinicDemo.Scheduling.Appointment discharge
{"resource":"Elixir.ClinicDemo.Scheduling.Appointment","action":"discharge",
 "policies":[
   {"description":"The schedule is readable by anything that can reach the application.",
    "access_type":"filter","bypass?":null,
    "condition":["action.type == :read"],"checks":["always true"]},
   {"description":"Only a signed-in member of staff may change the schedule.",
    "access_type":"filter","bypass?":null,
    "condition":["action.type in [:create, :update, :destroy]"],"checks":["actor is present"]}],
 "authorizers":["Ash.Policy.Authorizer"],
 "field_policies":[],
 "guidance":[
   "Authorization is deny-by-default: every policy that applies to the action must pass.",
   "Within a policy, the first authorize_if/forbid_if/authorize_unless/forbid_unless check that produces a decision decides the policy; remaining checks are skipped.",
   "authorize_if checks are alternatives (OR): any passing authorize_if makes the policy pass. ...",
   "bypass policies run before regular policies and, when their condition matches, can grant access regardless of the other policies — typically reserved for admins.",
   "Filter checks (:filter access type) scope the query instead of erroring: an unexpectedly empty result may mean the action was filtered rather than explicitly forbidden.",
   "To test a verdict, use Ash.can?/3 (or the generated can_<action>? code interface) with the intended actor rather than reasoning from the policy text alone."]}
```

Raw transcript: [`transcripts/ash-agent-forbidden-discharge.txt`](transcripts/ash-agent-forbidden-discharge.txt)
(one JSON line; `forbidden` is the one subcommand implemented inside
`bin/ash-agent` itself, via `mix run`, because `AshAgentTools.explain_forbidden/2`
has no Mix task behind it — logged in `.agents/logs/tool-gaps.log`).

`:discharge` is an update, so the second policy applies and it wants an actor.
The report lists what *can* deny; it does not run the check — which the last
guidance line says outright, and points at `Ash.can?/3` for the verdict.
