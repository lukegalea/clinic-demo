// The flight view's diagram engine, as its own esbuild entry.
//
// Mermaid is megabytes of JavaScript — the same reason the operator hub's
// diagram lives in operator_diagram.js — so the flight view keeps it out of
// app.js too: this entry is loaded at runtime by the FlightDiagram hook's
// dynamic import (an /assets URL left external by esbuild), so only /flight
// ever downloads it.
//
// The engine draws the server-rendered mermaid source once (the pinned
// definition is immutable — the diagram never re-renders) and places the
// live token markers on the node each token stands on: the mermaid node ids
// ARE the definition's element ids (AshBpmn.FlightView's documented
// round-trip), so an overlay positioned by node id lands on the element the
// token is on.
import mermaid from "mermaid"

mermaid.initialize({ startOnLoad: false, securityLevel: "strict" })

let sequence = 0

// Draws the diagram into the element's canvas child. Idempotent: the hook
// may call it again after a LiveView patch without re-rendering.
//
// The entry is bundled by esbuild as an IIFE (app.js is a classic script,
// so the shared esbuild invocation can't emit ESM), which strips `export` —
// so the engine publishes itself on `window.FlightViewEngine` for the hook.
async function mount(el) {
  if (el.dataset.flightMounted) return
  el.dataset.flightMounted = "true"

  const canvas = canvasOf(el)
  if (!canvas) return

  const { svg } = await mermaid.render(`flight-diagram-${++sequence}`, el.dataset.mermaid || "")
  canvas.innerHTML = svg

  // The svg scales to the container; keep the markers on their nodes when
  // it reflows. Re-placing reads the last payload off the element, so this
  // needs no server round trip.
  if (typeof ResizeObserver === "function") {
    new ResizeObserver(() => place(el, positionsOf(el))).observe(canvas)
  }

  place(el, positionsOf(el))
}

// Moves the markers to the latest positions. Replaces the marker layer's
// content in one pass — no LiveView re-render involved.
function place(el, positions) {
  const canvas = canvasOf(el)
  const layer = layerOf(el)
  if (!canvas || !layer) return

  el.dataset.positions = JSON.stringify(positions || [])
  layer.innerHTML = ""

  const wrap = el.getBoundingClientRect()

  for (const [index, position] of (positions || []).entries()) {
    const node = findNode(canvas, position.node_id)
    if (!node) continue

    const box = node.getBoundingClientRect()
    const anchor = document.createElement("a")
    anchor.href = position.href || "#"
    anchor.className = `flight-marker flight-marker--${position.status}`
    anchor.title = `${position.label} — ${position.node_name} (${position.status})`
    anchor.setAttribute("aria-label", anchor.title)
    anchor.textContent = position.initials || "?"
    // Stack markers that share a node slightly, so a parallel gateway with
    // two tokens reads as two visitors, not one.
    anchor.style.left = `${box.left - wrap.left + box.width / 2}px`
    anchor.style.top = `${box.top - wrap.top + box.height / 2 + index * 20}px`
    layer.appendChild(anchor)
  }
}

// Mermaid v12 renders node g elements with the id wrapped in its render
// prefix: "<render id>-flowchart-<node id>-<n>". The node id itself is
// sanitized to [A-Za-z_][A-Za-z0-9_]* (AshBpmn.FlightView's documented
// rule), so the wrapped form is matched by a word-boundary regex on the
// g.node ids; direct id/data-id matches stay first for older mermaids.
function findNode(canvas, nodeId) {
  return (
    canvas.querySelector(`[data-id="${nodeId}"]`) ||
    canvas.querySelector(`g.node[id="${nodeId}"]`) ||
    canvas.querySelector(`[id="${nodeId}"]`) ||
    Array.from(canvas.querySelectorAll("g.node")).find((node) => {
      const id = node.getAttribute("id") || ""
      return new RegExp(`(^|-)${nodeId}(-[0-9]+)?$`).test(id)
    })
  )
}

function canvasOf(el) {
  return el.querySelector("[data-flight-canvas]")
}

function layerOf(el) {
  return el.querySelector("[data-flight-markers]")
}

function positionsOf(el) {
  try {
    return JSON.parse(el.dataset.positions || "[]")
  } catch {
    return []
  }
}

window.FlightViewEngine = {mount, place}
