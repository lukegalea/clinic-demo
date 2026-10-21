// POC instrumentation for the surface's first paint, as performance marks:
//   atlas:app-js        the bundle started executing
//   atlas:placeholder   the server-rendered placeholder was in the HTML (if any)
//   atlas:skeleton      the hook's bootstrap skeleton appeared
//   atlas:skeleton-gone the hook removed it
//   atlas:placeholder-gone the placeholder handed over to the rendered surface
//   atlas:content       the surface has rendered its component tree
// Read with `performance.getEntriesByType("mark")` next to the paint entries.
// Imported first in app.js so it observes everything after it. Remove with
// the rest of the POC instrumentation.

export function markSurfaceTimeline() {
  performance.mark("atlas:app-js")
  const container = document.getElementById("ash-a2ui-surface")
  if (!container) return
  if (container.querySelector("[data-atlas-placeholder]")) performance.mark("atlas:placeholder")

  const seen = new Set()
  const mark = (name) => {
    if (seen.has(name)) return
    seen.add(name)
    performance.mark(name)
  }

  // The skeleton is a direct child of the container: a MutationObserver
  // sees it even when it lives for less than a frame.
  new MutationObserver((records) => {
    for (const record of records) {
      for (const node of record.addedNodes) {
        if (node.matches?.("[data-ash-a2ui-skeleton]")) mark("atlas:skeleton")
      }
      for (const node of record.removedNodes) {
        if (node.matches?.("[data-ash-a2ui-skeleton]")) mark("atlas:skeleton-gone")
        if (node.matches?.("[data-atlas-placeholder]")) mark("atlas:placeholder-gone")
      }
    }
  }).observe(container, {childList: true})

  // Polled per frame: the surface renders inside shadow roots, which a
  // MutationObserver on the container cannot see into.
  const started = performance.now()
  const tick = () => {
    const skeleton = container.querySelector(".ash-a2ui-skeleton")
    if (skeleton) mark("atlas:skeleton")
    if (seen.has("atlas:skeleton") && !skeleton) mark("atlas:skeleton-gone")
    const surface = container.querySelector("a2ui-surface")
    const rendered = [...(surface?.shadowRoot?.children || [])].some((el) => el.tagName !== "STYLE")
    if (rendered) mark("atlas:content")
    if (!seen.has("atlas:content") && performance.now() - started < 10000) requestAnimationFrame(tick)
  }
  requestAnimationFrame(tick)
}
