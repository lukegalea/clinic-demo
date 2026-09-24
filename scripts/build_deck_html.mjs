#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 Luke Galea
// SPDX-License-Identifier: MIT
//
// build_deck_html.mjs — the capstone slideshow as a static page (CLIN-6).
//
//   node scripts/build_deck_html.mjs
//
// Regenerates, from the slide content below:
//
//   priv/static/deck/index.html            the slideshow (11 slides)
//   priv/static/deck/deck.js               arrow-key navigation
//   priv/static/deck/shots/<name>.png      the screenshots it embeds
//   priv/static/deck/capstone-deck.pptx    copy of docs/capstone-deck.pptx
//                                          (the /deck download link)
//
// The slide text is the deck script's (/tmp/opencode/build_deck.js, the
// pptxgenjs source of docs/capstone-deck.pptx), transposed to HTML with the
// same neobrutalist tokens. The page is served by Plug.Static plus the
// /deck index route (PageController); its JS lives in deck.js — the app's
// CSP pins inline scripts, but an external script from 'self' passes as-is.
//
// Screenshot sources default to /tmp/opencode/deck-shots (the freshest
// captures); override with --shots <dir>. Zero dependencies; Node >= 18.

import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const OUT = path.join(ROOT, "priv", "static", "deck");
const SHOTS_OUT = path.join(OUT, "shots");

const args = process.argv.slice(2);
const shotsDir =
  args[args.indexOf("--shots") + 1] || "/tmp/opencode/deck-shots";

// The six screenshots the deck embeds — copied into priv/static/deck/shots
// so the committed page is self-contained.
const SHOTS = ["intake", "day", "operator", "board", "rules", "instance"];

// ── Slide content (from /tmp/opencode/build_deck.js) ───────────────────────

const pairSlides = [
  {
    kicker: "01 · surface → ui",
    title: "A form and a table, declared",
    file: "lib/clinic_demo_web/a2ui/intake_ui.ex",
    code: `use AshA2ui.Standalone

a2ui do
  for_resource ClinicDemo.Scheduling.Appointment

  component :form do
    fields [:patient_id, :clinician_id,
            :scheduled_at, :reason, :severity]
    create_action :book

    nested_form :patient do      # new patients,
      fields [:name, :species,   # right here
              :owner_email, ...]
    end
  end

  component :table, :recent do
    fields [:patient_label, :status,
            :triage_urgency]
    row_layout do
      badge :triage_urgency
    end
  end
end`,
    shot: "intake",
    label: "live at /intake",
    note: "No template was written for this page. The gated create panel opens front-and-center; the picker, the nested new-patient section, loading states and skeletons are the framework’s, themed through tokens.",
  },
  {
    kicker: "01b · host components → the day view",
    title: "Chrome around the data, hosted",
    file: "lib/clinic_demo_web/live/day_live.ex",
    code: `# not an a2ui surface — the NB layer
# (ash_a2ui's Lane D), themed by the
# same --a2ui-* tokens, no overrides:
<nb-calendar phx-hook="DayCalendar"
  month={@month}
  selected={Date.to_iso8601(@selected_day)}
  items={@item_dates} />

<nb-item phx-click="open_detail"
  status={status_vocab(@appointment)}
  label={"#{@appointment.patient_label}
          — #{@appointment.reason}"}
  meta={time_range(@appointment)}
  selectable />

<%!-- the day's tail folds natively --%>
<details :if={@earlier != []}>
  <summary>
    Earlier today ({length(@earlier)})
  </summary>
  ...
</details>`,
    shot: "day",
    label: "live at /day — earlier half unfolded",
    note: "The Day view is chrome around the data, so it hosts the NB component layer: a month grid, status-dotted visit rows, a read-only nb-sheet. The day's tail folds into a native <details> — and the seeds plant one earlier-today visit, so the fold always has a real past item to collapse.",
  },
  {
    kicker: "02 · state machine → diagram",
    title: "Four lines; the picture cannot drift",
    file: "lib/clinic_demo/scheduling/appointment.ex",
    code: `extensions: [AshStateMachine]

state_machine do
  state_attribute(:status)
  default_initial_state(:scheduled)

  transitions do
    transition(:check_in,
      from: :scheduled, to: :checked_in)
    transition(:complete,
      from: :checked_in, to: :completed)
    transition(:cancel,
      from: [:scheduled, :checked_in],
      to: :cancelled)
    transition(:mark_no_show,
      from: :scheduled, to: :no_show)
  end
end`,
    shot: "operator",
    label: "operator hub",
    note: "The operator hub renders this declaration as a Mermaid diagram — derived, never drawn by hand. Illegal transitions are refused by name: “from scheduled to completed” is what the error says.",
  },
  {
    kicker: "03 · policy → authorization",
    title: "Two policies gate the whole app",
    file: "lib/clinic_demo/scheduling/appointment.ex",
    code: `policies do
  policy action_type(:read) do
    authorize_if always()
  end

  policy action_type([
      :create, :update, :destroy]) do
    authorize_if actor_present()
  end
end

# config :ash_a2ui, actor: [
#   resource: ClinicDemo.Scheduling.Clinician,
#   label: :full_name]`,
    shot: "board",
    label: "the board",
    note: "Without a clinician picked at /acting-as, every write is refused — the board leads with the banner. The same declaration answers “why forbidden?” per policy, for agents and auditors alike.",
  },
  {
    kicker: "04 · rules → guard",
    title: "The rulebook is data, not code",
    file: "lib/clinic_demo/compliance/appointment_rules.ex",
    code: `use AshRules

rule "check-in requires a recorded weight",
  id: "appt.checkin_requires_weight",
  severity: :high do
  when_requires(
    has(:appointment, :transition_to,
        :checked_in))
  fails_when(
    neg(:appointment,
        :patient_weight_recorded, true))
  outcome(:noncompliant,
    gap: "record the patient's weight
          before check-in")
end

# riding the transition:
change {ComplianceGuard,
        transition_to: :checked_in}`,
    shot: "rules",
    label: "rule editor",
    note: "The module compiles to a content-hashed bundle; the guard evaluates the activated bundle — rules in force are rows, drafted and approved through the lifecycle. Blocked actions quote the gap text verbatim.",
  },
  {
    kicker: "05 · process → token",
    title: "A document, executed as rows",
    file: "priv/processes/appointment_visit.bpmn",
    code: `Start_booked
  → Triage        (business rule → DMN)
  → RecordUrgency (service → record_triage)
  → CheckIn       (user task, nurses)
  → Consult       (user task)
  → Discharge     (service)

# service tasks name the Ash action
# they call; the engine invokes it.

create :book do
  change StartVisitProcess  # in-txn
end`,
    shot: "instance",
    label: "instance viewer",
    note: "Booking starts the process inside the transaction. Open any visit from the hub: the diagram draws with the current node highlighted — waiting dashed, executing pulsing — and every guarded decision lands in the evidence trail.",
  },
];

const stackItems = [
  ["ash_a2ui", "Surfaces from DSL — forms, tables, panels, actor, presence & composer"],
  ["ash_bpmn", "Processes as BPMN documents — durable tokens over Postgres"],
  ["ash_decisions", "Decisions as DMN tables — versioned, evaluated, verifiable"],
  ["ash_rules", "Rule bundles — facts, outcomes, compile-to-hash"],
  ["ash_compliance", "The control plane — drafts, approvals, activations, evidence"],
  ["ash_agent_tools", "Agent introspection — describe, can, evaluate, edit"],
];

const agentRows = [
  ["ash_agent_tools", "describe / can / evaluate / edit — the contract, readable by machines; semantic edits with compile gates"],
  ["Tidewave MCP", "project_eval in the running app — Ash reflection, logs, SQL; get_docs at exact lockfile versions"],
  ["Serena-grade editing", "create ops + batch apply + formatter contract — agents author Ash DSL safely"],
  ["The agent console", "in-app: ask for an interface, it composes and verifies a surface live (LLM-backed, works keyless for browsing)"],
];

const demoBeats = [
  ["1", "Intake — one form books the visit; the row lands with triage already decided (the DMN answered in-transaction)."],
  ["2", "Pick a clinician, check the patient in on the board — the weight rule REFUSES it, quoting its rule id."],
  ["3", "Record the weight; check in again — it passes, the token advances, the instance viewer shows where the visit is."],
  ["4", "Open /operator/rules — the same rule, as data: draft, validate, approve, activate. The editor is the lifecycle."],
  ["5", "Ask the agent console for an interface — it composes and verifies a surface on the fly."],
  ["6", "/dev/dashboard — the running system: telemetry the app was born with, not wired up for the demo."],
];

// ── Renderers ──────────────────────────────────────────────────────────────

const esc = (s) =>
  s.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

const card = (body, cls = "") => `<div class="card ${cls}">${body}</div>`;
const chip = (text, cls = "chip-blue") => `<span class="chip ${cls}">${esc(text)}</span>`;
const titleBar = (kicker, title) => `
  <header class="slide-head">
    <p class="kicker">${esc(kicker)}</p>
    <h2>${esc(title)}</h2>
  </header>`;

function slide(inner, cls = "") {
  const n = slide.n++;
  return `<section class="slide ${cls}" id="slide-${n}" aria-label="Slide ${n} of ${slide.total}">
${inner}
</section>`;
}
slide.n = 1;
// Title, thesis, stack, six pair slides, agent story, demo script, closing.
slide.total = 12;

function pairSlide(p) {
  return slide(
    `${titleBar(p.kicker, p.title)}
    <div class="pair">
      ${card(
        `<p class="code-caption">${esc(p.file)}</p>
         <pre><code>${esc(p.code)}</code></pre>`,
        "code-card"
      )}
      <figure class="shot">
        <img src="/deck/shots/${p.shot}.png" alt="${esc(p.label)}" loading="lazy" />
        <figcaption>${chip(p.label, "chip-yellow")}</figcaption>
      </figure>
    </div>
    <p class="note">${esc(p.note)}</p>`
  );
}

const slides = [];

// 1 · Title
slides.push(
  slide(
    `<div class="title-stack">
      ${chip("PHOENIX · ASH · BPMN · DMN · RULES", "chip-yellow")}
      <h1>The Vet Clinic Capstone</h1>
      <p class="accent-line">Maximal Code</p>
      <p class="lede">Every moving part is a declaration. Everything the users see, the engine executes,<br />and the operator is refused by — is generated from it.</p>
      ${card(
        `<strong>7 frameworks, one thin shim.</strong> The demo after this deck is live — everything shown exists in the tree at HEAD.`,
        "note-card"
      )}
    </div>`,
    "slide-ink"
  )
);

// 2 · Thesis
slides.push(
  slide(
    `${titleBar("The thesis", "Not “no code.” Maximal code.")}
    <div class="cols-3">
      ${[
        ["DECLARE", "Small DSL blocks read like policy: a surface, a state machine, a rule, a process. One breath each."],
        ["GENERATE", "UI, diagrams, refusals, guards, tokens — derived from the declarations. No second artifact to drift."],
        ["RUN", "The declarations ARE the running system: policies gate, bundles guard, tokens advance, diagrams stay true."],
      ]
        .map(([h, body]) => card(`<h3 class="col-head">${h}</h3><p>${esc(body)}</p>`))
        .join("\n      ")}
    </div>
    ${card(
      `<strong>The rule:</strong> nothing generated that isn’t declared — and nothing declared that doesn’t generate. <span class="muted">When the schedule refuses a check-in, the message quotes the operator’s rule id. When the state machine diagram changes, it changed because the four transition lines changed.</span>`,
      "wide-card"
    )}`
  )
);

// 3 · Stack
slides.push(
  slide(
    `${titleBar("The stack", "Seven repos, one thin shim")}
    <div class="cols-3">
      ${stackItems
        .map(
          ([name, body]) =>
            card(`<h3 class="mono">${name}</h3><p>${esc(body)}</p>`)
        )
        .join("\n      ")}
    </div>
    ${card(
      `<strong>clinic-demo — the capstone shim.</strong> A handful of resource files, surface modules and two documents (BPMN + DMN). The frameworks do the rest — that’s the point of the demo.`,
      "wide-card card-yellow"
    )}`
  )
);

// 4–9 · the pair slides
for (const p of pairSlides) slides.push(pairSlide(p));

// 10 · Agent story
slides.push(
  slide(
    `${titleBar("The agent story", "The stack is agent-native, end to end")}
    <div class="rows">
      ${agentRows
        .map(
          ([name, body]) =>
            `<div class="row">${chip(name, "chip-soft")}<p>${esc(body)}</p></div>`
        )
        .join("\n      ")}
    </div>`
  )
);

// 11 · Demo script
slides.push(
  slide(
    `${titleBar("After this deck", "What to watch in the live demo")}
    <div class="rows">
      ${demoBeats
        .map(
          ([n, body]) =>
            `<div class="row"><span class="beat ${n === "2" || n === "4" ? "beat-yellow" : ""}">${n}</span><p>${esc(body)}</p></div>`
        )
        .join("\n      ")}
    </div>`
  )
);

// 12 · Closing
slides.push(
  slide(
    `<div class="title-stack">
      <h1>Nothing generated<br />that isn’t declared.</h1>
      <p class="accent-line">Nothing declared that doesn’t generate.</p>
      <p class="footer-line">The vet clinic capstone · Phoenix · Ash · ash_a2ui · ash_bpmn · ash_decisions · ash_rules · ash_compliance · ash_agent_tools</p>
    </div>`,
    "slide-ink"
  )
);

// ── deck.css (external on purpose) ─────────────────────────────────────────
//
// The app pages keep their CSS in external files, and the deck must too:
// the visual suite's volatile-text sanitizer rewrites DOM text nodes before
// a capture, and an inline <style>'s text node is exactly that — mutating a
// live stylesheet mid-capture takes the renderer down with the screenshot.
// External /deck/deck.css is never a text node, and style-src 'self' allows
// it unchanged.

const CSS = `
/* Self-hosted type (same files as the app: /fonts/, pinned in
   priv/static/fonts) — the deck's text metrics must not depend on a
   third party's font CDN either. */
@font-face {
  font-family: "DM Sans";
  font-style: normal;
  font-weight: 400 700;
  font-display: swap;
  src: url("/fonts/dm-sans-latin.woff2") format("woff2");
}
@font-face {
  font-family: "Archivo Black";
  font-style: normal;
  font-weight: 400;
  font-display: swap;
  src: url("/fonts/archivo-black-latin.woff2") format("woff2");
}
:root {
  --ink: #141414;
  --paper: #ffffff;
  --bg: #f2f7fe;
  --blue: #2563eb;
  --blue-soft: #dce9fc;
  --yellow: #ffd43b;
  --muted: #5b6472;
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; height: 100%; }
/* NOTE: the deck is a fixed-viewport page — slides are position:absolute in
   a 100dvh .deck, each slide scrolls internally (overflow:auto), so nothing
   ever overflows the body and NO clipping is needed anywhere. Do not add
   overflow:hidden to body or .deck: an overflow-clipped, full-height root
   hard-crashes Chromium's full-page capture (Page.captureScreenshot protocol
   error), which the visual suite's baseline needs. */
body {
  background: var(--bg);
  color: var(--ink);
  font-family: "DM Sans", ui-sans-serif, system-ui, sans-serif;
}
.deck { position: relative; width: 100vw; height: 100dvh; }
.slide {
  display: none;
  position: absolute;
  inset: 0;
  padding: 4.5vmin 5vmin 10vmin;
  flex-direction: column;
  gap: 2.2vmin;
  background: var(--bg);
  overflow: auto;
}
.slide.is-active { display: flex; }
.slide-ink { background: var(--ink); color: var(--paper); }
h1 { font-size: clamp(2.2rem, 6.5vmin, 4.6rem); line-height: 1.04; margin: 0; font-weight: 700; }
h2 { font-size: clamp(1.4rem, 3.6vmin, 2.4rem); margin: 0; font-weight: 700; }
.slide-head .kicker {
  margin: 0 0 0.6vmin;
  color: var(--blue);
  font-weight: 700;
  letter-spacing: 0.28em;
  text-transform: uppercase;
  font-size: clamp(0.6rem, 1.4vmin, 0.9rem);
}
.slide-ink .slide-head .kicker { color: var(--yellow); }
.chip {
  display: inline-block;
  width: fit-content;
  border: 2px solid var(--ink);
  border-radius: 999px;
  padding: 0.35em 0.9em;
  font-size: clamp(0.6rem, 1.5vmin, 0.85rem);
  font-weight: 700;
  box-shadow: -3px 3px 0 var(--ink);
}
.chip-yellow { background: var(--yellow); }
.chip-blue { background: var(--blue); color: var(--paper); }
.chip-soft { background: var(--blue-soft); }
.card {
  background: var(--paper);
  border: 2px solid var(--ink);
  border-radius: 10px;
  padding: 2vmin;
  box-shadow: -6px 6px 0 var(--ink);
  font-size: clamp(0.8rem, 1.8vmin, 1.05rem);
  line-height: 1.35;
}
.card h3 { margin: 0 0 1vmin; font-size: clamp(0.85rem, 2vmin, 1.2rem); }
.card .mono { font-family: ui-monospace, "Cascadia Mono", "Courier New", monospace; color: var(--blue); }
.card-yellow { background: var(--yellow); }
.cols-3 {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 2vmin;
}
.col-head { color: var(--blue); }
.rows { display: flex; flex-direction: column; gap: 1.6vmin; }
.row {
  display: flex;
  align-items: center;
  gap: 2vmin;
  background: var(--paper);
  border: 2px solid var(--ink);
  border-radius: 10px;
  box-shadow: -5px 5px 0 var(--ink);
  padding: 1.4vmin 2vmin;
}
.row .chip { flex: 0 0 auto; box-shadow: -3px 3px 0 var(--ink); }
.row p { margin: 0; font-size: clamp(0.8rem, 1.8vmin, 1.05rem); }
.beat {
  flex: 0 0 auto;
  display: grid;
  place-items: center;
  width: 2.6em;
  height: 2.6em;
  border: 2px solid var(--ink);
  border-radius: 10px;
  background: var(--blue);
  color: var(--paper);
  font-weight: 700;
  font-size: clamp(0.8rem, 2vmin, 1.2rem);
}
.beat-yellow { background: var(--yellow); color: var(--ink); }
.pair {
  display: grid;
  grid-template-columns: minmax(0, 6fr) minmax(0, 5.5fr);
  gap: 2.5vmin;
  flex: 1 1 auto;
  min-height: 0;
}
.code-card {
  display: flex;
  flex-direction: column;
  min-height: 0;
  overflow: auto;
}
.code-caption {
  margin: 0 0 1vmin;
  font-family: ui-monospace, "Courier New", monospace;
  font-weight: 700;
  font-size: clamp(0.6rem, 1.4vmin, 0.8rem);
  color: var(--muted);
}
.code-card pre {
  margin: 0;
  font-family: ui-monospace, "Cascadia Mono", "Courier New", monospace;
  font-size: clamp(0.62rem, 1.55vmin, 0.92rem);
  line-height: 1.3;
  white-space: pre;
}
.shot {
  margin: 0;
  background: var(--paper);
  border: 2px solid var(--ink);
  border-radius: 10px;
  box-shadow: -6px 6px 0 var(--ink);
  padding: 1.2vmin;
  display: flex;
  flex-direction: column;
  gap: 1vmin;
  min-height: 0;
}
.shot img {
  width: 100%;
  flex: 1 1 auto;
  min-height: 0;
  object-fit: contain;
  object-position: top left;
}
.shot figcaption { display: flex; }
.note { margin: 0; color: var(--muted); font-size: clamp(0.72rem, 1.7vmin, 1rem); }
.title-stack { display: flex; flex-direction: column; gap: 2.6vmin; margin: auto 0; }
.accent-line { color: var(--yellow); font-size: clamp(1.4rem, 4.4vmin, 3rem); font-weight: 700; margin: 0; }
.slide:not(.slide-ink) .accent-line { color: var(--blue); }
.lede { font-size: clamp(0.95rem, 2.2vmin, 1.4rem); margin: 0; }
.note-card { max-width: 60ch; background: #1e1e1e; border-color: var(--paper); box-shadow: -6px 6px 0 var(--paper); color: #cdd6e4; }
.note-card strong { color: var(--paper); }
.footer-line { color: #9aa7b8; font-size: clamp(0.65rem, 1.6vmin, 0.95rem); margin: 0; }
.wide-card { font-size: clamp(0.85rem, 2vmin, 1.15rem); }
.muted { color: var(--muted); }
.deck-hud {
  position: fixed;
  right: 3vmin;
  bottom: 3vmin;
  display: flex;
  align-items: center;
  gap: 1.2vmin;
  z-index: 10;
}
.deck-hud .counter {
  font-weight: 700;
  font-size: clamp(0.7rem, 1.7vmin, 1rem);
  padding: 0.4em 0.9em;
  border: 2px solid var(--ink);
  border-radius: 999px;
  background: var(--paper);
  box-shadow: -3px 3px 0 var(--ink);
}
.deck-hud button {
  font: inherit;
  font-weight: 700;
  font-size: clamp(0.8rem, 1.9vmin, 1.1rem);
  padding: 0.35em 0.95em;
  border: 2px solid var(--ink);
  border-radius: 10px;
  background: var(--yellow);
  box-shadow: -4px 4px 0 var(--ink);
  cursor: pointer;
}
.deck-hud button:active { translate: -2px 2px; box-shadow: -2px 2px 0 var(--ink); }
.deck-hud button:disabled { opacity: 0.35; cursor: default; }
.deck-hint {
  position: fixed;
  left: 3vmin;
  bottom: 3vmin;
  color: var(--muted);
  font-size: clamp(0.6rem, 1.5vmin, 0.85rem);
  z-index: 10;
}
.slide-ink ~ .deck-hint { color: #9aa7b8; }
@media (max-width: 900px) {
  .pair { grid-template-columns: 1fr; }
  .cols-3 { grid-template-columns: 1fr; }
}
`;

// ── deck.js (external: script-src 'self' — inline scripts are pinned) ──────

const DECK_JS = `// The deck's navigation: arrow keys (and friends), the HUD buttons, and a
// location hash that survives reloads. No dependencies; CSP-safe.
(() => {
  const deck = document.querySelector("main.deck");
  if (!deck) return;
  const slides = Array.from(deck.querySelectorAll(".slide"));
  const counter = document.querySelector(".deck-hud .counter");
  const prev = document.querySelector(".deck-hud [data-action=prev]");
  const next = document.querySelector(".deck-hud [data-action=next]");
  let index = 0;

  const apply = () => {
    slides.forEach((s, n) => s.classList.toggle("is-active", n === index));
    deck.setAttribute("data-current", String(index + 1));
    if (counter) counter.textContent = (index + 1) + " / " + slides.length;
    history.replaceState(null, "", index === 0 ? location.pathname : "#" + (index + 1));
    if (prev) prev.disabled = index === 0;
    if (next) next.disabled = index === slides.length - 1;
  };

  const go = (n) => {
    index = Math.max(0, Math.min(slides.length - 1, n));
    apply();
  };

  window.addEventListener("keydown", (event) => {
    if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey) return;
    switch (event.key) {
      case "ArrowRight":
      case "PageDown":
      case " ":
        event.preventDefault();
        go(index + 1);
        break;
      case "ArrowLeft":
      case "PageUp":
        event.preventDefault();
        go(index - 1);
        break;
      case "Home":
        event.preventDefault();
        go(0);
        break;
      case "End":
        event.preventDefault();
        go(slides.length - 1);
        break;
    }
  });

  if (prev) prev.addEventListener("click", () => go(index - 1));
  if (next) next.addEventListener("click", () => go(index + 1));

  const fromHash = parseInt(location.hash.slice(1), 10);
  go(Number.isInteger(fromHash) ? fromHash - 1 : 0);
})();
`;

// ── Assemble ───────────────────────────────────────────────────────────────

const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>The Vet Clinic Capstone — Maximal Code</title>
  <link rel="stylesheet" href="/deck/deck.css" />
  <script src="/deck/deck.js" defer></script>
</head>
<body>
  <main class="deck" data-testid="deck" data-current="1" aria-label="The Vet Clinic Capstone — slideshow">
${slides.join("\n")}
  </main>
  <footer class="deck-hud">
    <span class="counter">1 / ${slide.total}</span>
    <button type="button" data-action="prev" aria-label="Previous slide">&#8249; prev</button>
    <button type="button" data-action="next" aria-label="Next slide">next &#8250;</button>
  </footer>
  <p class="deck-hint">&larr;/&rarr; arrow keys &middot; Home/End</p>
</body>
</html>
`;

await mkdir(SHOTS_OUT, { recursive: true });
for (const name of SHOTS) {
  await copyFile(path.join(shotsDir, `${name}.png`), path.join(SHOTS_OUT, `${name}.png`));
}

await writeFile(path.join(OUT, "index.html"), html);
await writeFile(path.join(OUT, "deck.css"), CSS);
await writeFile(path.join(OUT, "deck.js"), DECK_JS);

// The download link on /operator points here; the pptx stays the property of
// its own generator (build_deck.js → docs/capstone-deck.pptx) — this copies.
try {
  await copyFile(
    path.join(ROOT, "docs", "capstone-deck.pptx"),
    path.join(OUT, "capstone-deck.pptx")
  );
} catch {
  console.warn("docs/capstone-deck.pptx not found — skipped the pptx copy");
}

console.log(
  `deck written: priv/static/deck/index.html (${slide.total} slides), deck.css, deck.js, ${SHOTS.length} shots`
);
