// Screenshot capture and baseline comparison.
//
// Baselines live in test/visual/__screenshots__/<page>.png and are committed.
// They are canonical for playwright@1.57.0's bundled Chromium at a 1280x800
// viewport (colorScheme: light). Before each capture the page's volatile
// text (seeded times, dates, counts) is digit-scrubbed and the presence
// chips are hidden, so a baseline only moves when the UI's structure moves.

import { readFile, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import pngjs from "pngjs";
import pixelmatch from "pixelmatch";

const { PNG } = pngjs;

const SCREENSHOTS_DIR = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "__screenshots__"
);

const MAX_DIFF_RATIO = 0.05; // a reflow moves far more than 5% of pixels
const PIXELMATCH_THRESHOLD = 0.2; // per-pixel color distance tolerance (AA noise)

export const VIEWPORT = { width: 1280, height: 800 };

export async function prepareForScreenshot(page) {
  // Presence chips are real people — they must never stabilise a baseline
  // nor shift one. The whole chip SLOT is removed from the DOM (not hidden:
  // an emptied slot keeps its margin/flex box, and 20px of ghost reflows the
  // nav's knife-edge row into a second row). Done from the DRIVER with
  // locators because the a2ui surfaces render the nav inside CLOSED shadow
  // roots, which no in-page stylesheet or querySelector can reach —
  // Playwright pierces them.
  const slots = page.locator(
    'nav[aria-label="Main"] a > span:has(span[aria-label*=" is on"]), nav[aria-label="Main"] a > span.ml-1:empty'
  );
  const count = await slots.count();
  for (let i = 0; i < count; i++) {
    await slots.nth(i).evaluate((el) => el.remove());
  }
  await page.evaluate(() => window.__sanitizeVolatileText());
}

export async function capture(page) {
  await page.evaluate(() => document.fonts.ready);
  // The first fullPage capture after a browser launch can die with a
  // "Protocol error (Page.captureScreenshot): Unable to capture screenshot"
  // — a Chromium compositing race, not a page defect. Retry ONCE, after a
  // pause: the tallest page here (the day grid, 10004x10794) allocates a
  // ~430MB raster per attempt, and an immediate second allocation lands
  // before the failed one is reclaimed — which takes the renderer down and
  // every check after it with it.
  try {
    return await page.screenshot({ fullPage: true, animations: "disabled" });
  } catch (error) {
    if (!/captureScreenshot/i.test(String(error))) throw error;
    await new Promise((resolve) => setTimeout(resolve, 1500));
    return page.screenshot({ fullPage: true, animations: "disabled" });
  }
}

async function ensureDir() {
  await mkdir(SCREENSHOTS_DIR, { recursive: true });
}

function artifactPath(name, suffix) {
  return path.join(SCREENSHOTS_DIR, `${name}${suffix}.png`);
}

// Returns { status: "match" | "updated" | "diff" | "missing-baseline", detail }.
// On "diff" the actual and diff images are written next to the baseline so a
// human (or the CI artifact upload) can see what moved.
export async function compareAgainstBaseline(name, currentPng, { updateBaselines = false } = {}) {
  await ensureDir();
  const baselineTarget = artifactPath(name, "");

  if (updateBaselines) {
    await writeFile(baselineTarget, currentPng);
    return { status: "updated", detail: "baseline written" };
  }

  let baseline;
  try {
    baseline = await readFile(baselineTarget);
  } catch {
    return {
      status: "missing-baseline",
      detail: `no committed baseline at test/visual/__screenshots__/${name}.png — run with --update-baselines`,
    };
  }

  const baselineImage = PNG.sync.read(baseline);
  const currentImage = PNG.sync.read(currentPng);

  if (
    baselineImage.width !== currentImage.width ||
    baselineImage.height !== currentImage.height
  ) {
    const actualPath = artifactPath(name, ".actual");
    await writeFile(actualPath, currentPng);
    return {
      status: "diff",
      detail:
        `page is ${currentImage.width}x${currentImage.height}, baseline is ` +
        `${baselineImage.width}x${baselineImage.height} — layout moved (actual saved to ${path.basename(actualPath)})`,
    };
  }

  const diff = new PNG({ width: currentImage.width, height: currentImage.height });
  const diffPixels = pixelmatch(
    currentImage.data,
    baselineImage.data,
    diff.data,
    currentImage.width,
    currentImage.height,
    { threshold: PIXELMATCH_THRESHOLD }
  );

  const total = currentImage.width * currentImage.height;
  const ratio = diffPixels / total;
  if (ratio > MAX_DIFF_RATIO) {
    const diffPath = artifactPath(name, ".diff");
    const actualPath = artifactPath(name, ".actual");
    await writeFile(diffPath, PNG.sync.write(diff));
    await writeFile(actualPath, currentPng);
    return {
      status: "diff",
      detail:
        `${(ratio * 100).toFixed(2)}% of pixels differ (${diffPixels}/${total}) ` +
        `(diff saved to ${path.basename(diffPath)})`,
    };
  }

  return { status: "match", detail: `${(ratio * 100).toFixed(2)}% of pixels differ` };
}
