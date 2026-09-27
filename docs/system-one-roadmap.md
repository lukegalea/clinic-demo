# System One — roadmap

> **Status: ROADMAP. Nothing on this page is built.** There is no `/agent`
> rung indicator, no evidence ledger, no credential domain, no `ollaya`
> process, no DMN band table, and no environment variable named below in
> this checkout today. Every route, resource, and file path mentioned here
> is a plan, not a pointer. This page exists so the shape of the work is
> legible before any of it lands — it gets replaced by real guided-tour
> steps and dated evidence transcripts, one piece at a time, as each one
> actually runs. It is never edited to sound more finished than the repo is.

This clinic keeps its **facts** (rules-as-data, a state machine, a DMN table,
a BPMN process) and its **guesses** in different places on purpose. System
One is the name for a planned addition that gives the guesses a place to
live *as guesses* — typed, timestamped, and never mistaken for a decision.

## The idea in one line

**Models observe. Declarations decide.**

Every probabilistic judgement the clinic will ever need — how urgent a
free-text reason sounds, whether a paragraph in a licence document supports
or contradicts a rule, whether an agent's next tool call matches what was
asked — is planned to be the answer to a *declared, typed question*, produced
by a small, swappable instrument, and turned into anything authoritative only
by the declarations that already run this application: a DMN table, an
`ash_rules` bundle, an Ash action held by an actor with a grant. The model is
never the thing that decides. It is one more thing the deciding layer is
allowed to read.

## The ladder

Four rungs, cheapest and most explainable first. Every answer that ships is
planned to say, in the UI itself, which rung produced it — something like
*"answered by System One · model@digest · p=0.94 · 7 ms"* — so nobody has to
trust a badge that hides which layer actually spoke.

1. **Declaration / FEEL / rules — free, exact, explainable.** Used whenever
   the question is not intrinsically about interpreting language: the DMN
   triage table, the state machine, the compliance rulebook. This is what
   the repo already runs, unchanged.
2. **System One — typed, calibrated, local by default.** A small model
   answers one of three question shapes — yes/no, a choice from a closed
   list, or a score in a range — and nothing else. It perceives; it never
   composes a rule, weighs precedence, or decides applicability. Planned
   default runtime: a local process (working binary name **`ollaya`**),
   speaking the same typed-answer wire shape a hosted fallback would use, so
   swapping instruments is a config change, not a rewrite.
3. **LLM — generative residue.** Free-text extraction, composition, or a
   drafted explanation, always labelled as commentary rather than evidence.
   Expensive, and every call is logged.
4. **Human — the middle band, and anything high-consequence.** A person's
   verdict is itself recorded, and repeated verdicts of the same shape are
   what eventually get *proposed* — never silently applied — as a rule-set
   revision.

Descending the ladder is planned to be triggered by calibrated uncertainty,
declared in a band table an operator can read and edit — never by an `if` in
application code.

## Demonstrations by audience

Three planned scenarios, one per audience this repo already speaks to. None
of them exist yet; each is written here as the shape of the demo, not a
description of running code.

### Coding agents

The repo's own agent tooling (`ash_agent_tools`, the laws judge, the two MCP
servers) is the first place a small local model is planned to appear,
strictly as **advisory, second-opinion signal** — it can flag or triage, it
can never change a deterministic verdict.

- **A pre-flight tool-call gate.** A deterministic allow/deny list runs
  first (this is just the repo's own written conventions, made checkable) —
  denying things like starting the dev server as a long-lived process, or
  editing a vendored path. What is left over gets a typed risk score and an
  intent guess from System One, banded by a DMN table an operator can edit —
  a band may only ever *raise* a request to "ask a human"; it can never allow
  a call outright and never deny one silently. The demo beat: an
  obviously-forbidden command denied instantly by the deterministic rung, and
  an obfuscated one flagged by System One and routed to "ask a human" — with
  the probability shown, not hidden behind a plain yes/no.
- **Laws-judge triage.** `mix ash_agent.laws` already reports violations at
  three certainty tiers and never touches its `definite` tier. The plan adds
  a System One pass over the `review` tier only, to sort a hit into
  "probably a real violation," "matches a documented exception," or "needs a
  human," while the deterministic tiers stay exactly as they are today.
- **Which MCP server should answer this?** A small model choosing between
  Serena and `ash_agent_tools` for a given question, scored honestly against
  a frontier model on the same forty questions — reported either way, a win
  or a loss.

**Where System One only adds, never replaces:** `ash_agent.validate`'s
contract checking stays exact — a model does not touch it. `did_you_mean`'s
existing Levenshtein-based suggestion also stays exactly as it is and remains
the contract; the plan adds a model-ranked suggestion only as a separate,
clearly labelled field beside it, with its options drawn from the action's
own real input contract, so it cannot invent a name — never merged into, and
never able to change, the deterministic suggestion. Where a declaration can
decide, a model is not meant to.

### Agents in `ash_ai`

The console's natural-language path (`RequestClassifier.interpret_request`,
today an LLM call with no fallback) is the planned first place a typed local
model takes over routing:

- **The intent classifier moves down a rung.** The same closed set of
  intents the console already declares becomes System One's question
  options directly, so the contract an agent tool would introspect and the
  options a model can answer from are the same list. A confident answer runs
  immediately; an unsure one still escalates to the existing LLM path
  exactly as it does today. The honest headline: this is planned to let the
  console's routing work **with no API key at all**, once a local model is
  running — a stronger story than today's honest failure without one.
- **A free-text reason becomes a severity suggestion, never a severity
  fact.** At intake, a proposed 1–5 score is planned to sit next to the
  field the receptionist actually typed, pre-filled and marked as a
  suggestion, with the DMN triage table still deciding only once a human has
  confirmed it. The safety rule this is built to hold: a suggestion may only
  *raise* the urgency band or add a "please check" flag — never quietly
  lower what a person entered. That asymmetry is planned to live in its own
  small DMN table, not in code, so it's an editable, auditable policy rather
  than a hidden `if`.
- **A guard on free text before any write.** Because the console is already
  read-only by construction, a guarded write tool is planned purely to
  demonstrate defence in depth: a screening pass over free-text fields
  before a tool call is allowed to run, logged either way.

### Rules and compliance — the headline demonstration

This is the planned public stand-in for a shape that shows up anywhere
compliance evidence has to be reconciled against a rule: **a supplier's
documents checked against a customer's requirements, per customer and
dated.** Wherever a real platform reconciles what a supplier submits against
what a customer requires, this demo maps a clinician's licence, insurance,
and controlled-drugs registration to what an appointment requires — same
mechanism, entirely synthetic clinic data, no real organisation's customers,
contracts, or documents anywhere near it.

The planned pipeline, end to end:

1. A synthetic credential document (a licence, a liability-insurance
   certificate, a drugs registration) is uploaded or renewed.
2. A deterministic step classifies the document type and routes it to the
   right rule family — no model involved yet.
3. System One reads the document in small, typed passes: *does this
   paragraph support or contradict this specific rule?* Each answer —
   `supports`, `contradicts`, `insufficient`, or `not applicable` — is
   recorded with the exact passage it came from, a probability, and which
   model version answered it. Never a bare "yes."
4. A DMN band table — thresholds an operator can see and edit — turns each
   answer into one of two outcomes: auto-admit only a `supports` answer at
   very high confidence, for a family granted that automation; everything
   else — every `contradicts` answer, at any confidence, and every
   "insufficient" answer — goes to a **human review** lane. There is no
   automatic fail: a contradiction is never quietly admitted as
   noncompliant, only ever routed to a person. Nothing uncertain is ever
   allowed to quietly become "compliant," either.
5. The middle lane is a real human task, showing the highlighted passage.
   Whatever the person decides is what becomes fact — and it is *that*
   decision, not the model's guess, that the rulebook ever reads.
6. The clinic's existing compliance guard reads the resulting fact the same
   way it already reads every other fact today, and a lapsed or unsupported
   credential is planned to block booking with a **"appointment at risk"**
   banner — the exact gap it can't cover, in plain language, the same way
   the compliance guard already surfaces gaps in this repo now.
7. Every verdict is planned to be reconstructable afterwards: which model
   answered, which version of the rulebook was active, which passage was
   read, and whether a human overrode it. That reconstruction is the audit
   pack, and it's the same record whether the answer that produced it came
   from a rule, a model, or a person.

A **calibration page** is planned alongside this, showing how well the
model's confidence actually tracks being right, on the labelled synthetic
set — with a banner saying plainly that a synthetic set proves the plumbing
works, not that the thresholds are trustworthy on anything real. Thresholds
earned this way are a plan, not a claim, until they're demonstrated.

## Data: synthetic, and marked as such everywhere

Every document, name, and licence number this demo will ever use is
invented, and every one carries the mark of it:

- obviously fictional names and clinics;
- licence and registration numbers in an unmistakable placeholder shape
  (`DEMO-VET-0001`, not a plausible real one);
- insurers that do not exist;
- a small set of hand-written templates with **planted defects** — an
  expired date, a mismatched name, an insurance limit just under the bar, a
  policy marked "pending" rather than in force, a missing signature — each
  one labelled, so the demo can show System One catching the planted defect
  or, just as honestly, missing it;
- fixtures kept under a dedicated path (planned: `priv/fixtures/system_one/`)
  and REUSE-annotated in their own right — this repository already carries a
  blanket `MIT` REUSE annotation (`REUSE.toml`) for its code, and the
  planned fixture set gets its own explicit annotation on top of that,
  naming it as generated synthetic data rather than real records;
- a generator, not a one-off: the plan is a small Mix task that produces the
  corpus from the templates, so the fixtures can be regenerated, extended,
  and reviewed rather than hand-maintained.

No real person's document, name, or credential is ever meant to touch this
repository. If that plan ever slips, that is a bug in the plan, not a
variant of it.

## Replay vs. live, and how each will be labelled

A demo that needs a running model to be believable, and silently doesn't
have one, is exactly the kind of demo this project's own standards rule out.
The plan is a labelled record/replay transport from the start:

- Every System One request is planned to be keyed by a hash of the model,
  the input state, and the question asked.
- A **replayed** answer — the default for CI and for a cold clone with no
  model running — is planned to say so, everywhere it's shown: *"replayed
  from a recording made \<date\> with \<model\>"*, never presented as a live
  answer wearing a live badge.
- A **live** answer — talking to a real `ollaya` process, or a hosted
  fallback — is planned to say that instead, with the same rung chip, so a
  reader can always tell which one they're looking at.
- Live mode is planned as something you opt into (a real model process
  running locally, or an explicit hosted-model flag), never something a cold
  clone silently falls back to expecting.

## What System One is built to never do

These are fences, not aspirations — they are the reason this whole plan is
compatible with the rest of the codebase's approach to authorization and
audit, and they're written here so the roadmap can be checked against them
once real code exists:

- **No model call inside a policy check, an authorization grant, a FEEL
  expression, a rules evaluation, or a projector.** A model may inform an
  authorization decision only through a recorded, versioned fact that a
  human or an explicit, narrow grant can still see and appeal — never by
  being asked live in the middle of deciding whether something is allowed.
- **A model answer is a fact with a timestamp, not something recomputed
  later.** Replaying history is planned to replay the recorded answer, never
  re-run the model and call that the same event.
- **Auto-admission, where it exists at all, is a narrow, named, revocable
  grant** — not a hidden confidence threshold, and it only ever admits a
  `supports` answer. A `contradicts` answer, at any confidence, always routes
  to a human instead — there is no silent auto-fail; a suggestion is never
  allowed to lower what a human already decided.
- **Thresholds live in an editable, versioned decision table, not in code.**
  A model upgrade is planned to be treated like a rule change: evaluated
  against a labelled set before it's trusted with anything new.

## Open questions this roadmap does not resolve

Written down rather than quietly assumed, because the honest version of a
roadmap says what it hasn't decided:

- Whether the compliance mechanism this demo will need (`ash_rules`,
  `ash_compliance`) can be published so this public repository stays
  cold-cloneable end to end — today those two dependencies are private,
  which already blocks a stranger from getting past `mix deps.get`,
  independent of anything System One adds.
- Which specific local model the demo settles on, and at what accuracy —
  vendor-reported numbers are not the same as numbers earned on this
  project's own labelled set, and this page makes no accuracy claim it
  hasn't verified itself.
- Whether a hosted fallback is demonstrated at all in the public repo, given
  that any hosted call is a real disclosure about where synthetic data
  travels, even when the data is fictional.

## Where this fits

- [`README.md`](../README.md) — the guided tour of everything that already
  runs.
- [`docs/storyline.md`](storyline.md) — the narrative the tour is a tour of.
- [`docs/agents.md`](agents.md) — the two agent-tooling MCP servers this
  plan's coding-agent scenarios build on top of.

When the first piece of this lands, it gets its own guided-tour step and its
own dated evidence transcript in `docs/evidence/`, exactly like everything
else in this repository — and this page shrinks to match, rather than
growing to sound finished.
