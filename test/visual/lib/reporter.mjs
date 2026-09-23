// Check recording and reporting. Every check prints exactly one line, and
// the exit code is decided from the tally — nothing else may fail the gate.
//
// Four verdicts:
//   PASS   — the assertion held.
//   FAIL   — it did not; blocks the gate.
//   XFAIL  — a known, deliberate gap asserted and confirmed to still exist,
//            marked with a TODO pointing at the lane that owns it. Does not
//            block the gate.
//   XPASS  — an XFAIL whose gap has vanished upstream. Informational; does
//            not block the gate, but the xfail marker should be removed.
//
// --grep <pattern>: only checks whose id contains the pattern run (page
// checks use the id prefix "page:<name>", behavioral pins "behavior:<id>").

export class Reporter {
  constructor({ grep = null } = {}) {
    this.grep = grep;
    this.passed = 0;
    this.failed = 0;
    this.xfailed = 0;
    this.xpassed = 0;
  }

  #visible(id) {
    return !this.grep || id.includes(this.grep);
  }

  // True when a block of work should execute at all under --grep.
  shouldRun(idPrefix) {
    return this.#visible(idPrefix);
  }

  #emit(line, id, detail) {
    if (!this.#visible(id)) return;
    console.log(`${line} ${id}${detail ? "  — " + detail : ""}`);
  }

  pass(id, detail = "") {
    if (!this.#visible(id)) return;
    this.passed++;
    this.#emit("PASS ", id, detail);
  }

  fail(id, detail = "") {
    if (!this.#visible(id)) return;
    this.failed++;
    this.#emit("FAIL ", id, detail);
  }

  xfail(id, detail = "") {
    if (!this.#visible(id)) return;
    this.xfailed++;
    this.#emit("XFAIL", id, detail);
  }

  xpass(id, detail = "") {
    if (!this.#visible(id)) return;
    this.xpassed++;
    this.#emit("XPASS", id, detail);
  }

  line(message) {
    console.log(message);
  }

  summary() {
    console.log(
      `== SUMMARY: ${this.passed} passed, ${this.failed} failed, ` +
        `${this.xfailed} expected-fail, ${this.xpassed} unexpectedly-passing ==`
    );
    return this.failed === 0;
  }
}

// Polls fn until it returns a truthy value or the timeout elapses. Playwright
// locators have their own waiting; this is for the evaluate-style probes.
export async function waitFor(desc, fn, { timeout = 8000, interval = 250 } = {}) {
  const start = Date.now();
  let lastError = null;
  while (Date.now() - start < timeout) {
    try {
      const value = await fn();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, interval));
  }
  const suffix = lastError ? ` (last error: ${String(lastError).slice(0, 200)})` : "";
  throw new Error(`timed out after ${timeout}ms waiting for ${desc}${suffix}`);
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function describeError(error) {
  return String(error && error.message ? error.message : error).replace(/\s+/g, " ").slice(0, 300);
}
