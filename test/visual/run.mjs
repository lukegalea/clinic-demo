#!/usr/bin/env node
// ClinicDemo standing visual/behavioral regression suite.
//
//   node run.mjs --base-url http://127.0.0.1:4000 [--update-baselines] [--grep <pattern>]
//
// Non-zero exit on any failure. Every check prints one PASS/FAIL line; the
// summary tallies at the end. Never pipe this through tail/grep without
// `set -o pipefail` — the exit code IS the gate.
//
// Three phases:
//
//   0. Prerequisites — the app answers, an actor is picked through
//      /acting-as (writes need an actor; the pill text and the nav presence
//      chips are checked on the way). The actor's session then parks on
//      /events — an a2ui surface whose presence topic no nav pill displays —
//      so the actor is alive for the behavioral pins without leaking a chip
//      into any screenshot baseline.
//   1. Page inventory — the fifteen standing surfaces, each checked for:
//      HTTP 200, /assets/js/app.js served, ZERO console errors/pageerrors,
//      the app chrome (nav, main, acting-as pill), the per-surface marker,
//      the computed-style dead-CSS audit on every visible labeled button,
//      and a full-page screenshot against the committed baseline.
//   2. Behavioral pins — the interaction contract from the view/edit/save
//      audit: the intake picker composite upgrades, searches and selects
//      once the create panel opens; View opens READ-ONLY; formless surfaces
//      have no View control; row-action success is visible; anonymous
//      writes are refused visibly; /events renders the seeded event stream
//      (bookings through discharge, DMN evaluations); a stale roster pick
//      redirects with a flash (no raw 422); and the process designer's
//      catalogue datalist is present.
//
// Conventions:
//   * Screenshot baselines: test/visual/__screenshots__/<page>.png, committed.
//     --update-baselines rewrites them (deliberate visual changes only).
//   * There are no expected-fails: every red line is a real regression.

import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { chromiumOptions, importPlaywright, resolveOptions } from "./lib/env.mjs";
import { DOM_INIT_SCRIPT } from "./lib/dom.mjs";
import {
  FORMLESS_SURFACES,
  PAGES,
  markerSelector,
} from "./lib/pages.mjs";
import {
  Reporter,
  describeError,
  sleep,
  waitFor,
} from "./lib/reporter.mjs";
import { VIEWPORT, capture, compareAgainstBaseline, prepareForScreenshot } from "./lib/shots.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const STALE_ACTOR_ID = "00000000-0000-0000-0000-000000000000";

// ── Browser/session helpers ────────────────────────────────────────────────

function newContextOptions() {
  return {
    viewport: VIEWPORT,
    deviceScaleFactor: 1,
    colorScheme: "light",
  };
}

async function newPageWithHelpers(browser) {
  const context = await browser.newContext(newContextOptions());
  const page = await context.newPage();
  await page.addInitScript(DOM_INIT_SCRIPT);
  return { context, page };
}

async function waitForApp(baseUrl, timeoutMs = 120_000) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${baseUrl}/`, { redirect: "follow" });
      if (response.ok) return;
      lastError = new Error(`HTTP ${response.status}`);
    } catch (error) {
      lastError = error;
    }
    await sleep(1000);
  }
  throw new Error(`app at ${baseUrl} did not answer within ${timeoutMs / 1000}s (${describeError(lastError)})`);
}

// The a2ui surfaces hydrate over the LiveView websocket after the document
// loads; giving them a moment lets the a2ui assertions run against real
// content. Pages without an <a2ui-surface> — or whose surface never
// hydrates (the canvas and agent pages render through other machinery) —
// resolve to false instead of failing: the per-surface marker carries the
// real assertion, this is only a settle wait.
async function waitForA2uiSurface(page, timeout = 20_000) {
  try {
    await page.waitForFunction(() => Boolean(document.querySelector("a2ui-surface")), null, { timeout: 3_000 });
  } catch {
    return false;
  }
  try {
    await page.waitForFunction(
      () => {
        const host = document.querySelector("a2ui-surface");
        return Boolean(host && host.shadowRoot && host.shadowRoot.childElementCount > 0);
      },
      null,
      { timeout }
    );
  } catch {
    return false;
  }
  return true;
}

async function goToPage(page, baseUrl, route) {
  const response = await page.goto(`${baseUrl}${route}`, { waitUntil: "networkidle", timeout: 30_000 });
  await waitForA2uiSurface(page);
  await sleep(1_000);
  return response;
}

// ── Phase 0: actor setup (the pill and presence ride along) ───────────────

async function pickActor(browser, reporter, baseUrl) {
  const pageId = "behavior:actor-pill";
  const { context, page } = await newPageWithHelpers(browser);

  await page.goto(`${baseUrl}/acting-as`, { waitUntil: "networkidle", timeout: 30_000 });
  const href = await page.locator('a[href*="/a2ui/actor"]').first().getAttribute("href");
  if (!href) {
    reporter.fail(pageId, "no roster entries on /acting-as — did the seeds run?");
    await context.close();
    return null;
  }

  // The switch is a full redirect by design (the session is written over
  // HTTP); a programmatic navigation has no referer, so the plug lands on /.
  await page.goto(`${baseUrl}${href}`, { waitUntil: "domcontentloaded" });
  await page.goto(`${baseUrl}/patients`, { waitUntil: "networkidle", timeout: 30_000 });
  await sleep(1_000);

  const pillText = (await page.locator('a[href="/acting-as"]').first().textContent()) || "";
  const label = pillText.replace(/\s+/g, " ").trim().replace(/^Acting as\s*/, "");

  if (/^Acting as\b/i.test(pillText.replace(/\s+/g, " ").trim()) && label) {
    reporter.pass(pageId, `pill shows "${label}", not the anonymous "Acting as…"`);
  } else {
    reporter.fail(pageId, `pill reads ${JSON.stringify(pillText.trim())}`);
    await context.close();
    return null;
  }

  return { context, page, label };
}

async function checkPresenceChips(browser, reporter, baseUrl, actorLabel) {
  // A second, anonymous session: anonymous visitors see every tracked
  // clinician (the self filter matches nothing without a stable key), so
  // whoever the helper is must show up on the Patients pill.
  const pageId = "behavior:presence-chips";
  const { context, page } = await newPageWithHelpers(browser);
  try {
    await page.goto(`${baseUrl}/patients`, { waitUntil: "networkidle", timeout: 30_000 });
    const chip = page.locator(`nav[aria-label="Main"] span[aria-label="${actorLabel} is on Patients"]`);
    await chip.waitFor({ state: "visible", timeout: 12_000 });
    reporter.pass(pageId, `chip "${actorLabel} is on Patients" visible to an anonymous visitor`);
  } catch (error) {
    reporter.fail(pageId, describeError(error));
  } finally {
    await context.close();
  }
}

// ── Phase 1: the page inventory ────────────────────────────────────────────

async function checkPage(reporter, baseUrl, pageDef, state) {
  const { page } = state.main;
  const id = (suffix) => `page:${pageDef.name}:${suffix}`;

  // HTTP.
  let response;
  try {
    response = await goToPage(page, baseUrl, pageDef.route);
  } catch (error) {
    reporter.fail(id("http"), describeError(error));
    return; // nothing downstream is meaningful on a dead navigation
  }

  if (response && response.status() === 200) {
    reporter.pass(id("http"), `GET ${pageDef.route} → 200`);
  } else {
    reporter.fail(id("http"), `GET ${pageDef.route} → ${response ? response.status() : "no response"}`);
  }

  // The wiped-asset guard.
  try {
    const asset = await page.context().request.get(`${baseUrl}/assets/js/app.js`);
    if (asset.status() === 200) {
      reporter.pass(id("app-js"), "/assets/js/app.js → 200");
    } else {
      reporter.fail(id("app-js"), `/assets/js/app.js → ${asset.status()}`);
    }
  } catch (error) {
    reporter.fail(id("app-js"), describeError(error));
  }

  // The app chrome: nav row, main region, acting-as pill. Standalone pages
  // (the /deck slideshow) opt out with `noChrome` — they are chrome-free by
  // design.
  if (!pageDef.noChrome) {
    try {
      const nav = page.locator('nav[aria-label="Main"]');
      const main = page.locator("main");
      const pill = page.locator('a[href="/acting-as"]');
      await Promise.all([
        nav.waitFor({ state: "visible", timeout: 8_000 }),
        main.first().waitFor({ state: "visible", timeout: 8_000 }),
        pill.first().waitFor({ state: "visible", timeout: 8_000 }),
      ]);
      reporter.pass(id("chrome"), "nav, main and acting-as pill present");
    } catch (error) {
      reporter.fail(id("chrome"), describeError(error));
    }
  }

  // The per-surface marker(s). A style/script marker (the ruleset editor's
  // inlined skin) can never be "visible" in the rendered-box sense — DOM
  // presence is the assertion there.
  const markers = [pageDef.marker, ...(pageDef.extraMarker ? [pageDef.extraMarker] : [])];
  const markerResults = [];
  for (const marker of markers) {
    try {
      const locator = page.locator(markerSelector(marker)).first();
      if (marker.hidden_ok) {
        await locator.waitFor({ state: "attached", timeout: 10_000 });
      } else {
        await locator.waitFor({ state: "visible", timeout: 10_000 });
      }
      markerResults.push(null);
    } catch (error) {
      markerResults.push(describeError(error));
    }
  }
  if (markerResults.every((r) => r === null)) {
    reporter.pass(
      id("marker"),
      markers.map((m) => (m.kind === "a2ui" ? "a2ui-surface hydrated" : m.text || m.selector)).join(" + ")
    );
  } else {
    reporter.fail(
      id("marker"),
      markerResults
        .map((r, i) => (r === null ? null : `marker ${JSON.stringify(markers[i])}: ${r}`))
        .filter(Boolean)
        .join("; ")
    );
  }

  // The nav pill owning this route must claim it (aria-current).
  if (pageDef.navCurrent) {
    try {
      const current = page.locator(
        `nav[aria-label="Main"] a[aria-current="page"][href="${pageDef.navCurrent}"]`
      );
      await current.waitFor({ state: "visible", timeout: 8_000 });
      reporter.pass(id("nav-current"), `aria-current points at ${pageDef.navCurrent}`);
    } catch (error) {
      reporter.fail(id("nav-current"), describeError(error));
    }
  }

  // The dead-CSS detector: every visible labeled button in app chrome and
  // framework chrome (one shadow level for a2ui hosts) must compute real
  // styling. A bare (preflight-only) or browser-default (outset border)
  // button is the dead-Tailwind incident wearing a different hat.
  try {
    const audit = await page.evaluate(() => window.__buttonStyleAudit());
    if (audit.offenders.length === 0) {
      reporter.pass(id("buttons"), `${audit.total} visible labeled button(s) compute styled chrome`);
    } else {
      const detail = audit.offenders.map((o) => `"${o.label}" (${o.host}): ${o.why}`).join("; ");
      reporter.fail(id("buttons"), `${audit.offenders.length}/${audit.total}: ${detail}`);
    }
  } catch (error) {
    reporter.fail(id("buttons"), describeError(error));
  }

  // Full-page screenshot against the committed baseline.
  try {
    await prepareForScreenshot(page);
    const png = await capture(page);
    const result = await compareAgainstBaseline(pageDef.name, png, {
      updateBaselines: state.updateBaselines,
    });
    if (result.status === "match") {
      reporter.pass(id("screenshot"), result.detail);
    } else if (result.status === "updated") {
      reporter.pass(id("screenshot"), `baseline written (test/visual/__screenshots__/${pageDef.name}.png)`);
    } else {
      reporter.fail(id("screenshot"), result.detail);
    }
  } catch (error) {
    reporter.fail(id("screenshot"), describeError(error));
  }

  // Console: zero errors/pageerrors, after everything on the page had its
  // chance to complain.
  const errors = state.console.snapshot();
  if (errors.length === 0) {
    reporter.pass(id("console"), "no console errors or page errors");
  } else {
    reporter.fail(id("console"), `${errors.length} error(s): ${errors.slice(0, 3).join(" | ")}`);
  }
}

// ── Phase 2: behavioral pins ───────────────────────────────────────────────

// Fills the first visible, non-search input on the page (the prompt modal's
// single field) the way a real keystroke would.
async function fillPromptInput(page, value) {
  return page.locator("input:visible").evaluateAll((elements, fill) => {
    const target = elements.find((el) => el.type !== "search");
    if (!target) return false;
    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
    setter.call(target, fill);
    target.dispatchEvent(new Event("input", { bubbles: true }));
    return true;
  }, value);
}

async function openRecordWeightPrompt(page) {
  const button = page.getByRole("button", { name: "Record weight" }).first();
  await button.waitFor({ state: "visible", timeout: 10_000 });
  await button.click();
  await waitFor("the Record weight prompt", async () => {
    const fillable = await page
      .locator("input:visible")
      .evaluateAll((els) => els.filter((el) => el.type !== "search").length);
    return fillable > 0;
  });
}

async function pinViewOpensReadOnly(reporter, helper, baseUrl) {
  const pageId = "behavior:view-opens-readonly";
  const page = helper.page;
  try {
    await goToPage(page, baseUrl, "/patients");
    const before = await page.evaluate(() => window.__editableControls());
    await page.getByRole("button", { name: "View", exact: true }).first().click();
    await page.locator('text="View patient"').first().waitFor({ state: "visible", timeout: 10_000 });
    await page.getByRole("button", { name: "Cancel" }).first().waitFor({ state: "visible", timeout: 5_000 });

    const after = await page.evaluate(() => window.__editableControls());
    if (after.length !== before.length) {
      reporter.fail(pageId, `editable controls went ${before.length} → ${after.length} with the panel open`);
    } else {
      reporter.pass(pageId, `"View patient" panel adds no editable controls (${after.length} before and after)`);
    }

    await page.getByRole("button", { name: "Cancel" }).first().click();
  } catch (error) {
    reporter.fail(pageId, describeError(error));
  }
}

async function pinFormlessSurfaces(reporter, baseUrl, page) {
  for (const route of FORMLESS_SURFACES) {
    const pageId = `behavior:formless-no-view:${route.replace(/\//g, "")}`;
    try {
      await goToPage(page, baseUrl, route);
      const count = await page.getByRole("button", { name: "View", exact: true }).count();
      if (count === 0) {
        reporter.pass(pageId, "no View row control on a formless surface");
      } else {
        reporter.fail(pageId, `${count} View control(s) on a surface with no form to view into`);
      }
    } catch (error) {
      reporter.fail(pageId, describeError(error));
    }
  }
}

async function pinRowActionSuccessVisible(reporter, helper, baseUrl) {
  const pageId = "behavior:row-action-success-visible";
  const page = helper.page;
  try {
    await goToPage(page, baseUrl, "/patients");
    await openRecordWeightPrompt(page);
    if (!(await fillPromptInput(page, "12.5"))) {
      reporter.fail(pageId, "no fillable input in the prompt");
      return;
    }
    await page.getByRole("button", { name: "Confirm" }).first().click();
    const feedback = page.locator("text=record_weight").first();
    await feedback.waitFor({ state: "visible", timeout: 10_000 });
    const text = (await feedback.textContent()) || "";
    reporter.pass(pageId, `feedback rendered: ${JSON.stringify(text.trim().slice(0, 80))}`);
  } catch (error) {
    reporter.fail(pageId, describeError(error));
  }
}

async function pinAnonWriteRefused(browser, reporter, baseUrl) {
  const pageId = "behavior:anon-write-refused";
  const { context, page } = await newPageWithHelpers(browser);
  try {
    await goToPage(page, baseUrl, "/patients");
    await openRecordWeightPrompt(page);
    if (!(await fillPromptInput(page, "12.5"))) {
      reporter.fail(pageId, "no fillable input in the prompt");
      return;
    }
    await page.getByRole("button", { name: "Confirm" }).first().click();
    const refusal = page.locator("text=/not authorized/i").first();
    await refusal.waitFor({ state: "visible", timeout: 10_000 });
    reporter.pass(
      pageId,
      `visible refusal: ${JSON.stringify(((await refusal.textContent()) || "").trim().slice(0, 80))}`
    );
  } catch (error) {
    reporter.fail(pageId, describeError(error));
  } finally {
    await context.close();
  }
}

async function pinEventsStreamRenders(browser, reporter, baseUrl) {
  const pageId = "behavior:events-stream-renders";
  const { context, page } = await newPageWithHelpers(browser);
  try {
    await goToPage(page, baseUrl, "/events");

    // The seeded story, asserted row by row: the lifecycle's bookings,
    // check-ins, completions and the discharge, plus a DMN triage
    // evaluation. ash_events appends `action on Resource` — the `what`
    // calculation on the audit resource — so each step has a distinct,
    // stable signature in the feed. Playwright's text engine pierces the
    // surface's open shadow root.
    const story = [
      /book\s+on\s+\S*ClinicDemo\.Scheduling\.Appointment/,
      /check_in\s+on\s+\S*ClinicDemo\.Scheduling\.Appointment/,
      /complete\s+on\s+\S*ClinicDemo\.Scheduling\.Appointment/,
      /discharge\s+on\s+\S*ClinicDemo\.Scheduling\.Appointment/,
      /create\s+on\s+\S*ClinicDemo\.Decisions\.Evaluation/,
    ];

    for (const pattern of story) {
      const row = page.locator(`text=${pattern}`).first();
      await row.waitFor({ state: "visible", timeout: 15_000 });
    }

    reporter.pass(pageId, "seeded event stream renders: bookings, check-ins, completions, the discharge and DMN evaluations");
  } catch (error) {
    reporter.fail(pageId, describeError(error));
  } finally {
    await context.close();
  }
}

async function pinStaleActorRedirect(browser, reporter, baseUrl) {
  const pageId = "behavior:stale-actor-redirect";
  const { context, page } = await newPageWithHelpers(browser);
  try {
    const response = await page.goto(`${baseUrl}/a2ui/actor?id=${STALE_ACTOR_ID}`, {
      waitUntil: "domcontentloaded",
      timeout: 30_000,
    });
    await page.waitForLoadState("networkidle");
    const status = response ? response.status() : 0;
    const landedOnPicker = new URL(page.url()).pathname === "/acting-as";
    const flash = page.locator('[data-testid="host-flash"]');
    const flashVisible = await flash.isVisible().catch(() => false);
    const flashText = flashVisible ? ((await flash.textContent()) || "").trim() : "";

    if (status === 200 && landedOnPicker && flashVisible && /no longer on the active roster/i.test(flashText)) {
      reporter.pass(pageId, `200 → /acting-as with flash ${JSON.stringify(flashText.slice(0, 80))}`);
    } else {
      reporter.fail(
        pageId,
        `status ${status}, landed ${page.url()}, flash=${JSON.stringify(flashText.slice(0, 80))} — raw 422 would show here`
      );
    }
  } catch (error) {
    reporter.fail(pageId, describeError(error));
  } finally {
    await context.close();
  }
}

// The picker composite: gated behind the create panel. The panel must be
// OPEN first — a pre-panel DOM check sees only the bare field and wrongly
// reports the composite missing. Then the combobox must upgrade (hook
// attached with its DOM id), search, and surface real options.
async function pinIntakePicker(reporter, baseUrl, page) {
  const pageId = "behavior:intake-picker-composite";
  try {
    await goToPage(page, baseUrl, "/intake");
    await page.getByRole("button", { name: "Create appointment" }).first().click();
    const field = page.locator('input[placeholder*="Type to search" i]').first();
    await field.waitFor({ state: "visible", timeout: 10_000 });
    await field.click();
    await field.fill("Bi");
    const option = page.locator('[role="option"]').first();
    await option.waitFor({ state: "visible", timeout: 8_000 });
    const optionText = ((await option.textContent()) || "").trim();
    if (!optionText) {
      reporter.fail(pageId, "options UI materialized but renders no option text");
      return;
    }
    reporter.pass(pageId, `panel-open picker searches and surfaces a real option: ${JSON.stringify(optionText.slice(0, 40))}`);
  } catch (error) {
    reporter.fail(pageId, describeError(error));
  }
}

// The deck (CLIN-6): the static slideshow must actually navigate with the
// arrow keys — a deck you cannot drive is a page with screenshots on it.
// Pins: slide 1 active on load, ArrowRight advances (data-current + the
// location hash agree), Home returns, End jumps to the closing slide.
async function pinDeckArrowKeys(reporter, baseUrl, page) {
  const pageId = "behavior:deck-arrow-keys";
  try {
    await goToPage(page, baseUrl, "/deck");
    const deck = page.locator('main[data-testid="deck"]');
    const current = () => deck.getAttribute("data-current");

    if ((await current()) !== "1") {
      reporter.fail(pageId, `deck opens on slide ${await current()}, not 1`);
      return;
    }

    await page.keyboard.press("ArrowRight");
    await deck.waitFor({ state: "visible" });
    await page.waitForFunction(
      () => document.querySelector('main[data-testid="deck"]').getAttribute("data-current") === "2",
      null,
      { timeout: 5_000 }
    );
    if (new URL(page.url()).hash !== "#2") {
      reporter.fail(pageId, `ArrowRight moved to slide 2 but hash is ${JSON.stringify(new URL(page.url()).hash)}`);
      return;
    }
    const active = await page.locator(".slide.is-active").getAttribute("id");
    if (active !== "slide-2") {
      reporter.fail(pageId, `active slide is #${active}, not #slide-2`);
      return;
    }

    await page.keyboard.press("End");
    await page.waitForFunction(
      () => document.querySelector('main[data-testid="deck"]').getAttribute("data-current") === "12",
      null,
      { timeout: 5_000 }
    );
    await page.keyboard.press("Home");
    await page.waitForFunction(
      () => document.querySelector('main[data-testid="deck"]').getAttribute("data-current") === "1",
      null,
      { timeout: 5_000 }
    );

    reporter.pass(pageId, "ArrowRight advances (hash syncs), End reaches slide 12, Home returns to 1");
  } catch (error) {
    reporter.fail(pageId, describeError(error));
  }
}

// The collapsed operations index (CLIN-5): the grid must be inside a native
// <details> that starts CLOSED and opens on the summary — the Day view's
// Earlier-today fold, applied to the hub.
async function pinOperatorIndexCollapsed(reporter, baseUrl, page) {
  const pageId = "behavior:operator-index-collapsed";
  try {
    await goToPage(page, baseUrl, "/operator");
    const details = page.locator('details[data-testid="operations-index-details"]');
    await details.waitFor({ state: "attached", timeout: 10_000 });

    if (await details.evaluate((el) => el.open)) {
      reporter.fail(pageId, "operations index renders expanded — must be collapsed by default");
      return;
    }
    const grid = page.locator('[data-testid="operations-index"] .grid');
    if (await grid.isVisible()) {
      reporter.fail(pageId, "index cards visible while the details is closed");
      return;
    }

    await details.locator("summary").click();
    await details.evaluate((el) => el.open).then((open) => {
      if (!open) throw new Error("summary click did not open the details");
    });
    if (!(await grid.isVisible())) {
      reporter.fail(pageId, "index cards still hidden after opening the details");
      return;
    }

    reporter.pass(pageId, "operations index collapsed by default; summary opens it; cards visible after");
  } catch (error) {
    reporter.fail(pageId, describeError(error));
  }
}

// The designer's catalogue renders as a datalist under the action field once
// a service task is selected — the "unconsumed framework skin" class of
// regression hides exactly here. Mounting the designer also get-or-creates
// the authoring DRAFT for the process, which the /processes page lists — so
// this runs as a warm-up BEFORE the screenshot phase: every run, on a dev
// box or a CI-fresh database, screenshots /processes with the same
// draft-present state.
async function pinDesignerDatalist(browser, reporter, baseUrl) {
  const pageId = "behavior:designer-datalist";
  const { context, page } = await newPageWithHelpers(browser);
  try {
    await goToPage(page, baseUrl, "/processes");
    const designerHref = await page.locator('a[href*="/designer"]').first().getAttribute("href");
    if (!designerHref) {
      reporter.fail(pageId, "no designer link on /processes");
      return;
    }
    await page.goto(`${baseUrl}${designerHref}`, { waitUntil: "networkidle", timeout: 30_000 });
    await waitFor("[data-element-id] shapes on the canvas", async () => {
      return (await page.locator("[data-element-id]").count()) > 0;
    });

    const taskId = await firstServiceTaskId();
    await page.locator(`[data-element-id="${taskId}"]`).first().click({ force: true });
    await page.locator("#config-action-options").waitFor({ state: "attached", timeout: 10_000 });
    await page.locator('#config-action[list="config-action-options"]').waitFor({ state: "visible", timeout: 10_000 });
    reporter.pass(pageId, `#${taskId} → #config-action[list="config-action-options"] + datalist`);
  } catch (error) {
    reporter.fail(pageId, describeError(error));
  } finally {
    await context.close();
  }
}

// The catalogue feeds the designer's combobox; the demo's committed process
// document says which shape carries a service binding.
async function firstServiceTaskId() {
  const fallback = "RecordUrgency";
  try {
    const bpmnPath = path.join(REPO_ROOT, "priv", "processes", "appointment_visit.bpmn");
    const xml = await readFile(bpmnPath, "utf8");
    const match = xml.match(/<bpmn2:serviceTask\s+id="([^"]+)"/);
    return match ? match[1] : fallback;
  } catch {
    return fallback;
  }
}

// ── Orchestration ──────────────────────────────────────────────────────────

async function main() {
  const options = resolveOptions(process.argv.slice(2));
  const reporter = new Reporter({ grep: options.grep });
  const state = { updateBaselines: options.updateBaselines, main: null };

  reporter.line(`== clinic-demo visual suite against ${options.baseUrl}${options.grep ? ` (grep: ${options.grep})` : ""} ==`);

  await waitForApp(options.baseUrl);
  const { chromium } = await importPlaywright();
  const browser = await chromium.launch({ ...chromiumOptions() });

  try {
    // Phase 0 — an actor, because writes need one and the chrome advertises it.
    const helper = await pickActor(browser, reporter, options.baseUrl);
    if (helper) {
      await checkPresenceChips(browser, reporter, options.baseUrl, helper.label);
      // Park the actor on /events: tracked, but its presence topic backs no
      // nav pill, so no chip leaks into any screenshot baseline below.
      await goToPage(helper.page, options.baseUrl, "/events");
    }

    // Phase 0.5 — the designer warm-up. Mounting the designer get-or-creates
    // the process's authoring draft, which /processes lists; doing this
    // before the inventory means the /processes screenshot always captures
    // the same draft-present state, on a dev box and on a CI-fresh database.
    if (reporter.shouldRun("behavior:designer-datalist") || reporter.shouldRun("page:processes")) {
      await pinDesignerDatalist(browser, reporter, options.baseUrl);
    }

    // The main anonymous session drives the page inventory and most pins.
    const main = await newPageWithHelpers(browser);
    const consoleErrors = [];
    main.page.on("console", (message) => {
      if (message.type() === "error") consoleErrors.push(message.text().slice(0, 300));
    });
    main.page.on("pageerror", (error) => consoleErrors.push(`pageerror: ${String(error).slice(0, 300)}`));
    state.main = main;
    state.console = {
      snapshot: () => consoleErrors.slice(),
      reset: () => (consoleErrors.length = 0),
    };

    // Phase 1 — the fifteen surfaces.
    for (const pageDef of PAGES) {
      if (!reporter.shouldRun(`page:${pageDef.name}`)) continue;
      state.console.reset();
      await checkPage(reporter, options.baseUrl, pageDef, state);
    }

    // Phase 2 — the behavioral contract.
    if (helper && reporter.shouldRun("behavior:view-opens-readonly")) {
      await pinViewOpensReadOnly(reporter, helper, options.baseUrl);
    } else if (!helper) {
      reporter.fail("behavior:view-opens-readonly", "no actor could be picked; pin skipped");
    }
    if (reporter.shouldRun("behavior:formless-no-view")) {
      await pinFormlessSurfaces(reporter, options.baseUrl, main.page);
    }
    if (helper && reporter.shouldRun("behavior:row-action-success-visible")) {
      await pinRowActionSuccessVisible(reporter, helper, options.baseUrl);
    } else if (!helper) {
      reporter.fail("behavior:row-action-success-visible", "no actor could be picked; pin skipped");
    }
    if (reporter.shouldRun("behavior:anon-write-refused")) {
      await pinAnonWriteRefused(browser, reporter, options.baseUrl);
    }
    if (reporter.shouldRun("behavior:events-stream-renders")) {
      await pinEventsStreamRenders(browser, reporter, options.baseUrl);
    }
    if (reporter.shouldRun("behavior:stale-actor-redirect")) {
      await pinStaleActorRedirect(browser, reporter, options.baseUrl);
    }
    if (reporter.shouldRun("behavior:intake-picker-composite")) {
      await pinIntakePicker(reporter, options.baseUrl, main.page);
    }
    if (reporter.shouldRun("behavior:deck-arrow-keys")) {
      await pinDeckArrowKeys(reporter, options.baseUrl, main.page);
    }
    if (reporter.shouldRun("behavior:operator-index-collapsed")) {
      await pinOperatorIndexCollapsed(reporter, options.baseUrl, main.page);
    }

    // Cleanup of the long-lived contexts.
    await main.context.close();
    if (helper) await helper.context.close();
  } finally {
    await browser.close();
  }

  const green = reporter.summary();
  if (reporter.passed + reporter.failed + reporter.xfailed + reporter.xpassed === 0) {
    console.error("FATAL: no checks ran — a --grep that matches nothing fails the run.");
    process.exit(2);
  }
  process.exit(green ? 0 : 1);
}

main().catch((error) => {
  console.error(`FATAL: ${describeError(error)}`);
  process.exit(1);
});
