# The storyline

This is the public narrative of the capstone demo — the short version of what
to look at and why, written to be readable without the six months of context
behind it. The README is the guided tour; this file is the story the tour is
a tour *of*. Every claim links to captured evidence under
[`docs/evidence/`](evidence/README.md), or says plainly that it could not be
captured.

## The pitch

A veterinary clinic's appointment book, written in Phoenix and Ash, is the
smallest honest stage for three questions every AI agent asks when it meets
an unfamiliar codebase — and for the three packages that answer them. An
agent that greps `def create` and guesses is doing what a new hire does; an
agent that asks the resource layer gets the contract, the ruling and the
process, in that order.

## Three questions, three answers

**"What does this action accept?"** — asked to `ash_agent_tools`. An Ash
action is not a function; it is data declared in a DSL, and the contract —
required inputs, types, constraints, file and line — is introspectable at
runtime. `describe` returns it as JSON; `validate` casts a proposed call
against it *without running anything*, so the camelCase typo comes back with
a spelling suggestion and the malformed UUID comes back as "is invalid"
instead of a 500. Evidence:
[03 — `ash_agent` answers](evidence/03-ash-agent-answers.md), and the negative
proof in [02 — the boundary](evidence/02-boundary-negative.md): a language
server's `find_symbol` for `complete` returns `[]`, correctly, because there
is no symbol called `complete`.

**"Why was that forbidden?"** — asked to the same resource layer. The
policies that *can* deny an action, in readable form, with the honest caveat
written into the tool itself: it lists what can deny, it does not rule; for a
verdict use `Ash.can?/3` with the actor you intend to use. Evidence: 03
again, `forbidden` section.

**"Where is this symbol, who calls it?"** — asked to
[Serena](https://github.com/oraios/serena) over an Elixir language server
([Expert](https://github.com/elixir-lang/expert)). Function bodies with line
spans in one round trip; cross-file references that cost a ten-second wait
exactly once, then 38ms. Evidence:
[01 — Serena end to end](evidence/01-serena-end-to-end.md),
[04 — the Expert fix](evidence/04-expert-fix.md),
[05 — waits](evidence/05-waits.md).

The two halves are complementary by structure, not taste: the language server
reads Elixir and cannot read Ash; the introspection layer reads Ash and does
not see functions. The boundary demo (02) is one screen and is the fastest
way to understand why the repo wires both.

## The two documents

Beside the resources sit two documents, and neither is Elixir. A DMN decision
table — seven rules, FEEL input entries, `PRIORITY` hit policy — decides how
urgent a visit is; a BPMN diagram walks the visit from the phone call to
discharge as durable tokens over Postgres. The composition rule that makes
the demo more than a technology pile: **a decision decides, the graph
orchestrates, and the Ash action is the only way anything changes** — the
process engine is refused by the same guards a person is, and there is a test
that asserts exactly that. The README's guided tour walks the whole story —
booking starts an instance, the first node asks the decision, the answer is
promoted onto the token, a gateway routes emergencies past an alert, and the
third seeded animal sits parked on a lab wait that survives a restart.

## The daemon, and the arithmetic it fixes

Every one of those introspection answers used to cost a Mix boot — paid on
*every* call, because each invocation was a fresh BEAM. The daemon
(`mix ash_agent.serve`) pays the boot once and answers from in-memory
compiled state over MCP-over-HTTP: same JSON, single-digit milliseconds per
call against seconds per call for the task path, with the protocol
negotiating down to older clients. Evidence, with transcripts and the clock:
[07 — the daemon slot](evidence/07-daemon-slot.md). The Mix tasks remain for
shells and CI; the two surfaces are the same tool with different transports.

## The honest boundary

The demo ships with its failures on the record, because a demo that hid them
would teach the wrong lesson.

- **`rename_symbol` does not work** — the move a "generic symbol half" is
  supposed to be for. Serena sends the LSP rename; Expert answers
  `Method not found (-32601)` because it declares no `renameProvider`. What
  was fixed: the `documentSymbol` crash that made even *reading* symbols
  unreliable was patched on our Expert fork (evidence 04). What remains: the
  rename provider itself, upstream. Evidence:
  [01](evidence/01-serena-end-to-end.md), recorded in the gap log with a
  date.
- **Known gaps in the packages**, listed in the README with reproduction
  shape rather than embarrassment: an xmerl encoding bug that keeps BPMN
  documents ASCII-only, a completed human task that cannot be read back, an
  ash_decisions verifier whose absence means the triage table's overlaps are
  reasoned about by hand rather than proved by a tool. Each is logged; each
  has a delete-this-rule-when-fixed note in `usage-rules.md`.

## Retrospective: what the dogfooding bought

The demo was used to build itself, and the loop was: hit the wall, log the
question in `.agents/logs/tool-gaps.log`, fix the tool, re-pin. Concretely:

- **Tool gaps logged, then fixed.** Three `ash_agent_tools` gaps found by
  working in this repository — domain-declared code interfaces reported
  empty, aggregates and calculations missing from resource descriptions,
  argument constraints absent from `describe`/`validate` — were fixed
  upstream in one commit (`f90c70e`) and the demo now runs the fixed
  package; the fourth (no Mix task for `explain_forbidden`) was closed from
  the other side by the daemon, where `ash_forbidden` is an ordinary tool.
  The gap log still names what is *not* fixed, which is the point of it.
- **Tool work shipped.** On `ash_agent_tools` master in the same window: the
  iron-law judge (`mix ash_agent.laws`), name-path resolution and semantic
  DSL edits, the supervised MCP daemon, and a trigger-eval gate runner that
  scores the daemon's tool-selection rate against a real client model —
  all seven tools pass the 75% gate. On the Expert fork: the
  `documentSymbol` fix that turns a `FunctionClauseError` into honest LSP.
- **CI debt cleared** in the reference application the demo was carved from:
  the three Credo findings blocking the build, every open security advisory,
  read-only CI keys for the two private dependencies, an Elixir 1.20 canary
  behind a warnings burn-down, and a Mint patch adopted the day its CVE
  landed.
- **Upstream adopted, not forked around.** Thirty-five commits of process
  engine work absorbed in one pinned jump rather than patched locally; the
  strangler package un-pinned the day its branch merged.

The meta-claim the demo makes is that this loop is the product: the gap log
is the input to the next round of tool work, and an empty log means nobody
tried.

## Where to go

- [`README.md`](../README.md) — the guided tour, ten steps, runnable as
  checked out.
- [`docs/agents.md`](agents.md) — the two-server wiring, the waits, and the
  daemon.
- [`docs/evidence/README.md`](evidence/README.md) — what was verified
  headlessly, and the precise shape of what was not.
