// The renderer contract, enforced in the only place it can be: a real
// browser. The Elixir-side emission test (test/clinic_demo_web/
// a2ui_emission_test.exs) catches object-valued text positions on the wire;
// this walks the rendered shadow DOM of every live surface and fails on any
// "[object Object]" — the signature of bindings the client never hydrated
// (see the evidence trail in config/config.exs).
//
// Not in CI (GitHub runners have no Chrome): run it against a live server —
//
//   npm i playwright@1.56.1            # once, anywhere node can resolve it
//   CHROME=/usr/bin/google-chrome \
//   PLAYWRIGHT_NODE_MODULES=/path/to/node_modules \
//   BASE=http://127.0.0.1:4000 node scripts/a2ui_render_probe.mjs
//
// Exits non-zero on the first failing route.

const BASE = process.env.BASE ?? "http://127.0.0.1:4000";

const playwrightModule = `${process.env.PLAYWRIGHT_NODE_MODULES ?? "."}/playwright/index.mjs`;
const { chromium } = await import(playwrightModule);

// kind "surface": a2ui surface — host div + interactive controls must render.
// kind "host":    the a2ui host container must exist (canvas/agent mount it;
//                controls appear only after a surface is presented).
// kind "plain":   any page — must load with zero "[object Object]" anywhere.
const routes = [
  { path: "/", kind: "surface" },
  { path: "/intake", kind: "surface" },
  { path: "/schedule", kind: "surface" },
  { path: "/worklist", kind: "surface" },
  { path: "/visits", kind: "surface" },
  { path: "/patients", kind: "surface" },
  { path: "/clinicians", kind: "surface" },
  { path: "/processes", kind: "surface" },
  { path: "/decisions", kind: "surface" },
  { path: "/evaluations", kind: "surface" },
  { path: "/events", kind: "surface" },
  { path: "/operator/rules", kind: "plain" },
  { path: "/emergencies", kind: "surface" },
  { path: "/operator", kind: "plain" },
  { path: "/acting-as", kind: "plain" },
  { path: "/canvas", kind: "host" },
  { path: "/agent", kind: "host" },
  { path: "/operator/tasks", kind: "plain" },
  { path: "/operator/processes/appointment_visit/designer", kind: "plain" },
  { path: "/operator/decisions/appointment.triage/editor", kind: "plain" },
  { path: "/clarity", kind: "plain", timeout: 60000 },
];

const browser = await chromium.launch({
  executablePath: process.env.CHROME ?? "/usr/bin/google-chrome",
  args: ["--no-sandbox", "--disable-dev-shm-usage"],
});

import { mkdirSync } from "node:fs";
if (process.env.SCREENSHOTS) mkdirSync("probe-screenshots", { recursive: true });

let failed = false;

for (const route of routes) {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));

  try {
    const response = await page.goto(`${BASE}${route.path}`, {
      waitUntil: "load",
      timeout: route.timeout ?? 30000,
    });
    await page.waitForTimeout(4000);

    const report = await page.evaluate(() => {
      const objectHits = [];
      let surfaceHost = false;
      const controls = new Set();

      const inspect = (root) => {
        const walker = document.createTreeWalker(
          root,
          NodeFilter.SHOW_TEXT,
          {
            // Script and style sources are code, not rendered UI — a
            // "[object Object]" in a bundle's source is not a page bug.
            acceptNode: (n) =>
              ["SCRIPT", "STYLE"].includes(n.parentElement?.tagName)
                ? NodeFilter.FILTER_REJECT
                : NodeFilter.FILTER_ACCEPT,
          }
        );
        while (walker.nextNode()) {
          const t = walker.currentNode.textContent ?? "";
          if (t.includes("[object Object]")) objectHits.push(t.trim().slice(0, 80));
        }
      };

      const pierce = (node) => {
        if (node.id === "ash-a2ui-surface") surfaceHost = true;
        if (node.tagName) controls.add(node.tagName.toLowerCase());
        if (node.shadowRoot) {
          inspect(node.shadowRoot);
          node.shadowRoot.querySelectorAll("*").forEach(pierce);
        }
        if (node.querySelectorAll) node.querySelectorAll("*").forEach(pierce);
      };

      pierce(document.body);
      inspect(document.body);

      const interactive = ["a2ui-basic-button", "ash-a2ui-choicepicker", "a2ui-basic-textfield", "a2ui-list"].filter(
        (tag) => controls.has(tag)
      );

      return { objectHits: objectHits.length, surfaceHost, interactive };
    });

    const problems = [];
    // goto follows redirects and does NOT throw on HTTP errors — a 404 error
    // page would otherwise pass every text check (this exact false positive
    // hid a missing route once).
    const status = response?.status() ?? 0;
    if (status !== 200) problems.push(`HTTP ${status}`);
    if (report.objectHits > 0) problems.push(`${report.objectHits} "[object Object]"`);
    if (route.kind !== "plain" && !report.surfaceHost) problems.push("no surface host rendered");
    if (route.kind === "surface" && report.interactive.length === 0) {
      problems.push("no a2ui controls rendered");
    }
    if (errors.length > 0) problems.push(`page errors: ${errors[0]}`);

    if (problems.length > 0) {
      failed = true;
      console.log(`FAIL ${route.path} — ${problems.join("; ")}`);
    } else {
      console.log(`OK   ${route.path}${route.kind === "surface" ? ` (${report.interactive.length} control kinds)` : ""}`);
    }

    if (process.env.SCREENSHOTS) {
      await page.screenshot({
        path: `probe-screenshots/${route.path.replaceAll("/", "-") || "-root"}.png`,
        fullPage: true,
      });
    }
  } catch (error) {
    failed = true;
    console.log(`FAIL ${route.path} — ${String(error).slice(0, 160)}`);
  } finally {
    await page.close();
  }
}

await browser.close();
process.exit(failed ? 1 : 0);
