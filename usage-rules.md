# Rules for working in clinic_demo

A small veterinary scheduling application in three layers: an Ash domain that
holds the schedule, a DMN decision that says how urgent a visit is, and a BPMN
process that walks a visit from the phone call to the front door. It exists to
be read by agents as much as by people, which is why the conventions below are
written down rather than inferred from the code.

Read this before writing anything here. The three sentences that matter most:

> **A decision decides.** It never acts, never validates and never authorizes.
>
> **The process graph orchestrates.** It never decides, validates or authorizes
> either.
>
> **The Ash action is the only way anything changes.** Every caller, including
> the process engine, goes through it and is refused by the same guard.

## Iron laws

This project adopts the 26 Iron Laws that `ash_agent_tools` ships as its
`iron-laws` sub-rule, and judges against them deterministically:

```sh
mix ash_agent.laws $(git diff --name-only --diff-filter=d main | grep '\.exs\?$')
git diff main | mix ash_agent.laws - --diff     # added lines only
mix ash_agent.laws lib/clinic_demo/rules.ex --min-tier review --pretty
```

The judge is advisory and pattern-based, not an oracle. Two standing
dispositions in this repository, so nobody re-litigates them:

- **Law 21 (`no-assign-new-for-per-mount-values`)** fires all over
  `core_components.ex`. Those are function components, where `assign_new/3` is
  the sanctioned use the law itself names. Not a violation here.
- **Law 16 (`external-resource-for-compile-time-files`)** fires on
  `ClinicDemo.Rules.read!/1`. Deliberate: the DMN and BPMN documents are read at
  runtime, not compiled in, because the whole reason a rule lives outside code
  is so that changing it does not need a deploy.

Anything else the judge reports gets fixed or gets a line here.

## Before you write against the contract, read it

`ash_agent_tools` is a dev dependency and answers in JSON. Ask it rather than
grepping:

```sh
mix ash_agent.describe ClinicDemo.Scheduling.Appointment book
mix ash_agent.validate ClinicDemo.Scheduling.Appointment book '<json>'
mix ash_agent.search triage
mix ash_agent.context lib/clinic_demo/scheduling/appointment.ex:174
```

The first invocation pays a Mix boot, so batch the questions. If a tool cannot
answer what you need, fall back to grep and append one line to
`.agents/logs/tool-gaps.log`: a timestamp and the question you could not
answer. That log is the input to the next round of tool work, and an empty log
means nobody tried.

## Rules

### The domain

1. **Every state change is its own named action.** There is no generic
   `:update` on `Appointment`, and there will not be one. `:book`,
   `:reschedule`, `:check_in`, `:complete`, `:cancel`, `:record_triage`,
   `:mark_no_show` and `:discharge` each carry their own arguments, their own
   guard on the prior status, and their own description. An action whose
   description you cannot write in one sentence is two actions.
2. **Guard the prior state with `CurrentStatusIn`.** Every transition declares
   which statuses it will accept. This is what makes the process engine safe to
   point at the domain: a node that fires twice, or fires early, is refused the
   same way a person would be.
3. **Call through the domain's code interface.** `ClinicDemo.Scheduling`
   defines one function per action. Reach for `Ash.Changeset.for_*` only when
   the interface genuinely cannot express what you need, and add the interface
   when it can.
4. **Never hand-write a migration.** `mix ash.codegen <name>` after a resource
   change; review what it produced; commit the snapshots with it.
5. **No raw SQL.** Filters, aggregates and calculations are Ash expressions.

### Decisions

6. **A decision decides; the caller acts.** `appointment.triage` answers a
   question and returns a string. `Appointment.:record_triage` is what writes
   it down. Never let a decision reach a mutation, and never let a caller
   invent an urgency of its own.
7. **The DMN document is the single artifact.** `priv/decisions/*.dmn` is the
   rule. Do not mirror a rule table in Elixir, in a config file, or in a
   database table. The moment a second copy exists, somebody edits one of them.
8. **Publishing is one-way, and a changed rule is a new version.** Edit the
   document, `ClinicDemo.Rules.install!/0`, done. There is no editing a
   published definition.
9. **Callers do not pin a version.** `Decisions.Resolver` asks for the latest
   published every time, deliberately: the reason a clinic keeps triage
   thresholds out of code is so a head vet can change one without a deploy.
10. **Every value into a decision goes through
    `AshDecisions.Feel.to_feel_value/2`.** FEEL numbers are decimal, so a plain
    Elixir integer turns `>= 4` into a type error, which is `null`, which the
    table reads as "no rule matched" — a silently empty table that reports
    nothing anywhere.
11. **Keep the table complete and honest.** Declare `inputValues` on every
    column, type every column, and end with a catch-all rule. A table with a
    gap answers `null` for the inputs nobody thought about.

### Processes

12. **The BPMN document is the single artifact**, on the same terms as the DMN
    one. `priv/processes/*.bpmn`. No code DSL, no generated XML, no second copy
    of the graph.
13. **A token carries routing, not business data.** Node ids, status, and the
    scalar signals a decision promoted. Everything else is read off the
    appointment, live, at execution time. If you find yourself wanting to carry
    clinical text on a token, the answer is an Ash action, not a bigger token.
14. **A business rule task asks; a gateway reads the answer.** The composition
    is always: business rule task → promote a named signal → gateway tests
    `routing.<name>`. A gateway that dereferenced a decision would do I/O in a
    path that is otherwise pure, and would put the rule back inside the graph.
15. **Declare what a node reads.** `ash:load` names the relationships and
    calculations a node's expressions need. An undeclared path is `null`, which
    is honest and quiet — and quiet is the problem, so declare it.
16. **Service tasks call code interfaces, as the actor the engine gave you.**
    `ctx[:actor]` is a named system actor, not `nil`, and not a reason to pass
    `authorize?: false`. An engine write that could not be attributed is an
    audit trail with a hole in it.
17. **Invoker callbacks tolerate a second invocation.** Node execution may run
    twice. Name the state your action produces and return `:ok` without calling
    again once the appointment is already in it. Do not achieve this by
    swallowing errors: a `:discharge` that is refused because nobody wrote the
    visit up is not the same thing as one that already happened.
18. **Publish the decision before the process.** The process's
    `businessRuleTask` is verified against the decision resolver at publish
    time. `ClinicDemo.Rules.install!/0` does them in order; so should you.
19. **Keep BPMN documents ASCII.** `ash_bpmn`'s XML reader hands xmerl
    codepoints rather than octets, so anything above 127 — an em dash in a
    comment, an accented name — fails the parse. Recorded in
    `.agents/logs/tool-gaps.log`.
20. **Do not read a completed human task.** `HumanTask.outcome` is an untyped
    atom, so a value written to the column cannot be loaded back, and any query
    that touches a completed task raises. Filter on
    `status in [:open, :claimed]`, and read tokens and process events rather
    than `AshBpmn.instance_report/2` when the instance has finished a task.
    Also recorded in the gap log; delete this rule when the package fixes it.

### Tests

21. **The rules are installed once, in `test/test_helper.exs`,** before the
    sandbox goes manual, so they are committed rows every test can see.
    Publishing costs an `xmllint` spawn and a compile; that is not a per-test
    price.
22. **Test the negative paths.** A process suite that only walks the happy path
    is testing a distributed system for the absence of its defining property.
    The no-show branch and the refused discharge are both covered; keep it that
    way.
23. **`mix precommit` before you claim you are done.** Compile with warnings as
    errors, unused deps, format, test.

## Layout

```
lib/clinic_demo/
  scheduling/            the domain: patients, clinicians, appointments
  decisions/             DMN definitions, the evidence trail, the BPMN bridge
  visits/                the six BPMN resources and the three host callbacks
  rules.ex               publishes both documents from priv/, in order
priv/
  decisions/*.dmn        the triage table
  processes/*.bpmn       the visit process
```
