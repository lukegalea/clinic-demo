// Environment resolution for the visual suite.
//
// Two supported ways to run:
//
//   1. Plain (CI, and the usual local path):
//        npm ci && npx playwright install --with-deps chromium
//        node run.mjs --base-url http://127.0.0.1:4000
//      Playwright and its bundled Chromium come from this directory's
//      node_modules. The committed screenshot baselines are canonical for
//      the bundled Chromium that playwright@1.57.0 drives.
//
//   2. Vendor fallback (no network, browsers already on the box):
//        PLAYWRIGHT_NODE_MODULES=/path/to/node_modules \
//        CHROME=/usr/bin/google-chrome \
//        node run.mjs --base-url http://127.0.0.1:4000
//      Playwright is imported from PLAYWRIGHT_NODE_MODULES and CHROME is
//      used as the browser executable. Note: a system Chrome renders text
//      slightly differently from the bundled Chromium, so screenshot
//      comparisons may need --update-baselines after deliberate changes.

const DEFAULT_BASE_URL = "http://127.0.0.1:4000";

export function resolveOptions(argv) {
  const options = {
    baseUrl: process.env.BASE_URL || DEFAULT_BASE_URL,
    updateBaselines: false,
    grep: null,
  };

  const args = [...argv];
  while (args.length > 0) {
    const arg = args.shift();
    if (arg === "--base-url") {
      const value = args.shift();
      if (!value) throw new Error("--base-url requires a value");
      options.baseUrl = value.replace(/\/+$/, "");
    } else if (arg === "--update-baselines") {
      options.updateBaselines = true;
    } else if (arg === "--grep") {
      const value = args.shift();
      if (!value) throw new Error("--grep requires a pattern");
      options.grep = value;
    } else {
      throw new Error(
        `unknown argument: ${arg} (usage: node run.mjs --base-url <url> [--update-baselines] [--grep <pattern>])`
      );
    }
  }

  return options;
}

export async function importPlaywright() {
  const vendor = process.env.PLAYWRIGHT_NODE_MODULES;
  if (vendor) {
    return import(`${vendor}/playwright/index.mjs`);
  }
  return import("playwright");
}

export function chromiumOptions() {
  if (process.env.CHROME) return { executablePath: process.env.CHROME };
  // Software rasterization, no /dev/shm dependency. The typefaces are
  // self-hosted (priv/static/fonts), so these flags cannot drift text
  // metrics — they only remove the GPU/EGL path, whose init fails
  // intermittently on a memory-pressured host and takes full-page captures
  // of the tall pages (the day grid is 10004x10794) down with it.
  return { args: ["--disable-gpu", "--disable-dev-shm-usage"] };
}
