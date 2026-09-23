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
  window.__buttonStyleAudit = () => {
    const out = { total: 0, offenders: [] };
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
        const sides = ["Top", "Right", "Bottom", "Left"];
        const noBorder = sides.every((s) => parseFloat(cs["border" + s + "Width"]) === 0);
        const noShadow = !cs.boxShadow || cs.boxShadow === "none";
        const bg = cs.backgroundColor;
        const transparent = bg === "transparent" || bg === "rgba(0, 0, 0, 0)";
        if (noBorder && noShadow && transparent) {
          out.offenders.push({ label, host: root.host ? root.host.tagName.toLowerCase() : "document", why: "no border, no shadow, no background" });
        } else if (cs.borderTopStyle === "outset") {
          out.offenders.push({ label, host: root.host ? root.host.tagName.toLowerCase() : "document", why: "browser-default outset border" });
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
  // the day CI replays it. Runs only on text nodes, and only right before a
  // capture — all structural checks run on the real content.
  window.__sanitizeVolatileText = () => {
    let touched = 0;
    const scrub = (r) => {
      for (const node of r.querySelectorAll("*")) {
        for (const child of node.childNodes) {
          if (child.nodeType === 3 && /[0-9]/.test(child.textContent)) {
            child.textContent = child.textContent.replace(/[0-9]/g, "8");
            touched++;
          }
        }
        if (node.shadowRoot) scrub(node.shadowRoot);
      }
    };
    scrub(document);
    return touched;
  };

  // Presence chips ("RV is on Board") are real people — they must not
  // stabilise a baseline nor break one. visibility:hidden keeps the layout.
  window.__hidePresenceChips = () => {
    const style = document.createElement("style");
    style.id = "visual-suite-hide-chips";
    style.textContent =
      'nav[aria-label="Main"] span[aria-label*=" is on"] { visibility: hidden !important; }';
    document.head.appendChild(style);
  };
})();
`;
