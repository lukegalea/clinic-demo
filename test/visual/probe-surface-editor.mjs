// The composer's end-to-end proof on the live app: browse → import →
// rejections visible → edit → preview renders → export shows DSL source.
import { chromium } from "playwright";

const BASE = process.env.BASE_URL || "http://localhost:4000";

const browser = await chromium.launch({ executablePath: process.env.CHROME });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });

const step = (name, ok, extra = "") => {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${extra ? " — " + extra : ""}`);
  if (!ok) process.exitCode = 1;
};

await page.goto(`${BASE}/operator/surfaces`, { waitUntil: "networkidle" });

// 1. browse: one card per declared surface, h1 ours
step("browse: h1 Surface editor", await page.locator("h1:text-is('Surface editor')").count() === 1);
step("browse: PatientUI card listed", (await page.content()).includes("PatientUI"));

// 2. import: pick the patients surface
await page.click("button[phx-value-module='ClinicDemoWeb.A2ui.PatientUI']");
await page.waitForSelector("text=imported from ClinicDemoWeb.A2ui.PatientUI");
step("import: editor opened", true);

// 3. rejections visible — every declared demo surface carries some
// (surface ids/record labels are resolve metadata, not spec vocabulary)
await page.waitForSelector("[aria-label='Import rejections']");
const rejectionText = await page.locator("[aria-label='Import rejections']").innerText();
step(
  "import: rejections honestly rendered",
  rejectionText.includes("surface_id") && rejectionText.includes("a2ui."),
  rejectionText.split("\n").filter((l) => l.includes("("))[0]
);

// 4. preview rendered (the spec resolves out of the box)
await page.waitForSelector("#composer-preview");
const preview = await page.locator("#composer-preview").innerText();
step("preview: resolved entities", preview.includes("table") && preview.includes("dyn_"), preview.split("\n")[1]);

// 5. edit: change the title, watch the preview + export follow
await page.fill("#composer-spec-title", "Playwright-edited title");
await page.waitForSelector("text=Playwright-edited title");
const previewAfter = await page.locator("#composer-preview").innerText();
step("edit: preview follows", previewAfter.includes("Playwright-edited title"));

// 6. export: DSL source, copyable, reflects the edit
const source = await page.inputValue("#composer-export-source");
step(
  "export: DSL source",
  source.startsWith("defmodule ClinicDemoWeb.A2ui.ComposedSurface do") &&
    source.includes("Playwright-edited title") &&
    source.includes("use AshA2ui.Standalone"),
  `${source.length} chars`
);

await page.screenshot({ path: "probe-screenshots/surface-editor-flow.png", fullPage: false });

await browser.close();
console.log(process.exitCode ? "== E2E FAILED ==" : "== E2E GREEN ==");
