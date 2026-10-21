// Removes the server-rendered surface placeholder (Atlas.Surface.container/1)
// once the A2UI surface has rendered its component tree, so the placeholder
// covers the whole wait: bundle, socket join, bootstrap and first render.
// Runs on load and after every live navigation. A surface that has not
// rendered after 10 s drops its placeholder anyway: a loader that never ends
// would claim progress that is not happening.

const LIMIT_MS = 10000
const watching = new WeakSet()

export function clearPlaceholders() {
  const run = () => document.querySelectorAll("[data-atlas-placeholder]").forEach(watch)
  run()
  window.addEventListener("phx:page-loading-stop", run)
}

function watch(placeholder) {
  if (watching.has(placeholder)) return
  watching.add(placeholder)
  const container = placeholder.parentElement
  const started = performance.now()

  const tick = () => {
    if (!placeholder.isConnected) return
    const surface = container.querySelector("a2ui-surface")
    const rendered = [...(surface?.shadowRoot?.children || [])].some((el) => el.tagName !== "STYLE")
    if (rendered) {
      // Wait for the surface's pending Lit render, then one frame, so the
      // tree is painted before the placeholder leaves: no blank frame.
      Promise.resolve(surface.updateComplete).then(() => requestAnimationFrame(() => placeholder.remove()))
    } else if (performance.now() - started > LIMIT_MS) {
      placeholder.remove()
    } else {
      requestAnimationFrame(tick)
    }
  }
  requestAnimationFrame(tick)
}
