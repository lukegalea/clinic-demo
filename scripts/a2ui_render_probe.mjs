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

const routes = [
  "/schedule",
  "/worklist",
  "/visits",
  "/patients",
  "/clinicians",
  "/processes",
  "/decisions",
  "/evaluations",
  "/emergencies",
  "/acting-as",
];

const browser = await chromium.launch({
  executablePath: process.env.CHROME ?? "/usr/bin/google-chrome",
  args: ["--no-sandbox", "--disable-dev-shm-usage"],
});

let failed = false;

for (const route of routes) {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 160)));

  try {
    await page.goto(`${BASE}${route}`, { waitUntil: "load", timeout: 30000 });
    await page.waitForTimeout(4000);

    const report = await page.evaluate(() => {
      const objectHits = [];
      let surfaceHost = false;
      const controls = new Set();

      const inspect = (root) => {
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
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

    const a2uiRoute = route !== "/acting-as";
    const problems = [];
    if (report.objectHits > 0) problems.push(`${report.objectHits} "[object Object]"`);
    if (a2uiRoute && !report.surfaceHost) problems.push("no surface host rendered");
    if (a2uiRoute && report.interactive.length === 0) problems.push("no a2ui controls rendered");
    if (errors.length > 0) problems.push(`page errors: ${errors[0]}`);

    if (problems.length > 0) {
      failed = true;
      console.log(`FAIL ${route} — ${problems.join("; ")}`);
    } else {
      console.log(`OK   ${route}${a2uiRoute ? ` (${report.interactive.length} control kinds)` : ""}`);
    }

    if (process.env.SCREENSHOTS) {
      await page.screenshot({ path: `probe-screenshots${route.replaceAll("/", "-") || "-root"}.png`, fullPage: true });
    }
  } catch (error) {
    failed = true;
    console.log(`FAIL ${route} — ${String(error).slice(0, 160)}`);
  } finally {
    await page.close();
  }
}

await browser.close();
process.exit(failed ? 1 : 0);
