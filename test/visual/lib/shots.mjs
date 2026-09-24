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
  await page.evaluate(() => window.__hidePresenceChips());
  await page.evaluate(() => window.__sanitizeVolatileText());
}

export async function capture(page) {
  await page.evaluate(() => document.fonts.ready);
  // The first fullPage capture after a browser launch can die with a
  // "Protocol error (Page.captureScreenshot): Unable to capture screenshot"
  // — a Chromium compositing race, not a page defect (it reproduces on
  // long-standing pages too, and the immediate retry always passes). Retry
  // once before calling it a failure.
  try {
    return await page.screenshot({ fullPage: true, animations: "disabled" });
  } catch (error) {
    if (!/captureScreenshot/i.test(String(error))) throw error;
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
