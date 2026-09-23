// The operator hub's visit-state-machine diagram, as its own esbuild entry.
//
// Mermaid is megabytes of JavaScript — far too much to push into app.js,
// which every page loads — so this entry is bundled separately and included
// only by the pages that actually carry a [data-mermaid] element. The chart
// source is server-rendered by AshStateMachine.Charts (derived from the
// resource's declaration, never user input), and a <pre> holding the raw
// source is the no-JS fallback: this scan replaces it with the rendered SVG.
import mermaid from "mermaid"

mermaid.initialize({startOnLoad: false, securityLevel: "strict"})

const renderMermaidCharts = () => {
  document.querySelectorAll("[data-mermaid]").forEach((el, index) => {
    if (el.dataset.mermaidRendered) return
    mermaid.render(`mermaid-chart-${index}`, el.dataset.mermaid).then(({svg}) => {
      el.innerHTML = svg
      el.dataset.mermaidRendered = "true"
    })
  })
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", renderMermaidCharts)
} else {
  renderMermaidCharts()
}
