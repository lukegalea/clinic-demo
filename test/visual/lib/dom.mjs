// In-page DOM helpers, installed on every page via addInitScript before any
// navigation. Everything the runner asserts on lives in the light DOM plus
// (for the a2ui surfaces) open shadow roots, so plain functions are enough —
// no framework runtime is involved.
//
// Playwright's own selector engine already pierces open shadow roots; these
// helpers exist for the two checks that need custom traversal: the
// computed-style dead-CSS audit (which deliberately limits shadow piercing
// to one level of a2ui hosts) and the volatile-text sanitizer that runs
// before screenshots.

export const DOM_INIT_SCRIPT = /* js */ `
(() => {
  // Every reachable root: document plus ALL open shadow roots, recursively.
  window.__allRoots = () => {
    const roots = [document];
    const walk = (r) => {
      for (const el of r.querySelectorAll("*")) {
        if (el.shadowRoot) { roots.push(el.shadowRoot); walk(el.shadowRoot); }
      }
    };
    walk(document);
    return roots;
  };

  // The audit's traversal contract for the dead-CSS detector: the app chrome
  // (light DOM) plus ONE level of shadow under a2ui/ash-* custom elements —
  // the a2ui surfaces host their row buttons exactly one level down. Deeper
  // framework internals (bpmn-js canvas pieces, picker plumbing) are skipped.
  window.__chromeRoots = () => {
    const roots = [document];
    for (const el of document.querySelectorAll("*")) {
      if (/^(a2ui-|ash-)/i.test(el.tagName) && el.shadowRoot) roots.push(el.shadowRoot);
    }
    return roots;
  };

  window.__norm = (s) => (s || "").replace(/\\s+/g, " ").trim();

  // Visible = laid out with a nonzero box. Not "in viewport": the feedback
  // line at the bottom of tall surfaces counts as rendered.
  window.__visible = (el) => {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };

  // The dead-CSS detector. A visible, text-bearing button "computes bare"
  // when it has no border, no shadow and no background — the preflight-only
  // look that killed the buttons in the dead-Tailwind incident — or when it
  // carries the browser-default outset border (the never-styled look).
  // Icon-only buttons are skipped: the theme toggle's three segments are
  // deliberately flat inside a chrome-bearing container.
  //
  // Two button kinds are flat BY DESIGN in the ash_a2ui admin catalog (the
  // A2UI 1.0 renderer; sortable headers 1.7, reference links), and are held
  // to their own affordance contract instead of the chrome rule — a flat
  // look is not "dead CSS" when the stylesheet that makes it flat is the
  // thing that loaded:
  //   - sort header: <th aria-sort="ascending|descending|none"> wrapping a
  //     <button class="sort-button"> (all: unset, so no chrome of its own)
  //     that reads as clickable: cursor:pointer.
  //   - reference link: <button class="am-link"> in a table cell, drawn as
  //     an underlined link: cursor:pointer + an underline.
  // A flat button that breaks its contract (no pointer cursor, no aria-sort
  // on its header, a link with no underline) is still an offender: that is
  // the lost-affordance regression the audit exists to catch.
  window.__flatAffordanceProblem = (b, cs) => {
    if (b.classList.contains("sort-button")) {
      const th = b.closest("th");
      const sort = th && th.getAttribute("aria-sort");
      if (!["ascending", "descending", "none"].includes(sort)) return "sort header without aria-sort on its th";
      if (cs.cursor !== "pointer") return "sort header without a pointer cursor";
      return null;
    }
    if (b.classList.contains("am-link")) {
      if (cs.cursor !== "pointer") return "reference link without a pointer cursor";
      if (!/underline/.test(cs.textDecorationLine)) return "reference link without an underline";
      return null;
    }
    return undefined;
  };

  window.__buttonStyleAudit = () => {
    const out = { total: 0, flat: 0, offenders: [] };
    const seen = new Set();
    for (const root of window.__chromeRoots()) {
      for (const b of root.querySelectorAll("button")) {
        if (!window.__visible(b)) continue;
        const label = window.__norm(b.textContent);
        if (!label) continue;
        const key = label + "@" + (root.host ? root.host.tagName.toLowerCase() : "doc");
        if (seen.has(key)) continue;
        seen.add(key);
        out.total++;
        const cs = getComputedStyle(b);
        const host = root.host ? root.host.tagName.toLowerCase() : "document";
        const flat = window.__flatAffordanceProblem(b, cs);
        if (flat !== undefined) {
          if (flat === null) out.flat++;
          else out.offenders.push({ label, host, why: flat });
          continue;
        }
        const sides = ["Top", "Right", "Bottom", "Left"];
        const noBorder = sides.every((s) => parseFloat(cs["border" + s + "Width"]) === 0);
        const noShadow = !cs.boxShadow || cs.boxShadow === "none";
        const bg = cs.backgroundColor;
        const transparent = bg === "transparent" || bg === "rgba(0, 0, 0, 0)";
        if (noBorder && noShadow && transparent) {
          out.offenders.push({ label, host, why: "no border, no shadow, no background" });
        } else if (cs.borderTopStyle === "outset") {
          out.offenders.push({ label, host, why: "browser-default outset border" });
        }
      }
    }
    return out;
  };

  // Editable controls anywhere on the page (shadow-inclusive), for the
  // read-only-view panel pin.
  window.__editableControls = () => {
    const out = [];
    for (const root of window.__allRoots()) {
      for (const el of root.querySelectorAll("input, textarea, select")) {
        if (!window.__visible(el)) continue;
        if (el.disabled || el.readOnly || el.getAttribute("aria-readonly") === "true") continue;
        out.push({ tag: el.tagName.toLowerCase(), type: el.type || null });
      }
    }
    return out;
  };

  // Screenshot sanitizer: every ASCII digit becomes an "8", same glyph, same
  // class of width, so seeded times ("tomorrow_at 9"), dates, ids and counts
  // stop moving the pixels between the day the baseline was committed and
  // the day CI replays it. Long hex runs (bundle content hashes, the sha
  // fingerprints the surfaces print) get the same treatment including their
  // letters — digits alone left a-f on the table, and a fresh seed's hash
  // width moved the page 2px. Runs only on text nodes, and only right before
  // a capture — all structural checks run on the real content.
  window.__sanitizeVolatileText = () => {
    let touched = 0;
    // Weekday and month names change with the calendar, not with the code:
    // the day view's heading reads "Thursday, 24 September" one day and
    // "Friday, 25 September" the next. Swap them for fixed tokens FIRST
    // (same scrub for every run of the week), then let the digit scrub
    // handle the numbers.
    const CAL_WORDS =
      /\b(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|January|February|March|April|May|June|July|August|September|October|November|December)\b/g;
    const scrub = (r) => {
      for (const node of r.querySelectorAll("*")) {
        // Never touch stylesheet/script text: a <style> is a live stylesheet,
        // and mutating one mid-capture takes the renderer down (this crashed
        // captures of pages with in-shadow <style> blocks — the calendar's).
        if (node.nodeName === "STYLE" || node.nodeName === "SCRIPT") continue;
        for (const child of node.childNodes) {
          if (child.nodeType === 3) {
            const text = child.textContent;
            if (/[0-9]/.test(text) || /[0-9a-f]{8,}/i.test(text) || CAL_WORDS.test(text)) {
              CAL_WORDS.lastIndex = 0;
              child.textContent = text
                .replace(CAL_WORDS, (word) => "DayInYear".slice(0, word.length))
                .replace(/[0-9a-f]{8,}/gi, (run) => run.replace(/[0-9a-f]/gi, "8"))
                .replace(/[0-9]/g, "8");
              touched++;
            }
            CAL_WORDS.lastIndex = 0;
          }
        }
        if (node.shadowRoot) scrub(node.shadowRoot);
      }
    };
    scrub(document);
    return touched;
  };

  // NOTE: presence chips ("RV is on Board") are removed by the DRIVER before
  // a capture (shots.mjs / prepareForScreenshot) — they are real people and
  // must never stabilise a baseline nor shift one, and only a Playwright
  // locator reaches the nav inside the a2ui surfaces' CLOSED shadow roots.
})();
`;
