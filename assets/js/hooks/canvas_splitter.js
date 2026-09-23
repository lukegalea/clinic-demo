/**
 * CanvasSplitter LiveView hook — the /canvas shell's row splitter.
 *
 * A small custom implementation on purpose (pointer-event drag updating
 * the shell's `grid-template-rows`, nothing else): the interaction is two
 * event handlers and one style write, and a library would drag in far more
 * than it saves. Escape hatch: if this ever grows past ~200 lines —
 * snap-to guides, multi-divider algebra, touch inertia — swap the drag
 * internals for split.js behind the same data-* API. Measure first.
 *
 * Contract (all via data attributes on the divider element):
 *
 *   phx-hook="CanvasSplitter"
 *   role="separator" aria-orientation="vertical" tabindex="0"
 *   data-target="#canvas-shell"          — the grid whose rows we resize
 *   data-pane="#canvas-pane-graph"       — the pane this divider grows
 *   data-layout-key="canvas-shell"       — localStorage key suffix
 *   data-min="160"                       — px floor for the pane
 *
 * Behavior:
 *   - pointer drag writes `grid-template-rows` (a single style write per
 *     frame, rAF-coalesced; no layout reads in the move path);
 *   - the graph's Cytoscape instance redraws on drag-END only
 *     (`cy.resize()` through the element's public `cy` getter — the
 *     element's own ResizeObserver keeps the buffer fresh meanwhile;
 *     expensive relayout/fit never runs during a drag);
 *   - sizes persist to localStorage under `clinic-demo:layout:<key>`;
 *   - double-click or Enter/Space resets this divider (clears the stored
 *     size, restores the stylesheet's track);
 *   - keyboard matches the canvas's arrow/Enter/Escape model (roving
 *     tabindex stays inside the graph element; there is no F6 pattern to
 *     match): Up/Down move the divider (Shift = coarse), Home/End to the
 *     extremes, Escape cancels a drag restoring the pre-drag size;
 *   - no transitions are attached to the tracks, so drags are motion-free;
 *     collapse state rides `aria-expanded`/`aria-hidden` flips owned by the
 *     markup's JS.toggle commands.
 */

const STORAGE_PREFIX = "clinic-demo:layout:";

export const CanvasSplitter = {
  mounted() {
    this.shell = document.querySelector(this.el.dataset.target);
    this.pane = document.querySelector(this.el.dataset.pane);
    this.key = STORAGE_PREFIX + (this.el.dataset.layoutKey || "canvas");
    this.min = parseInt(this.el.dataset.min || "160", 10);
    this.dragging = false;

    this.restore();

    this.onPointerDown = (event) => this.startDrag(event);
    this.onPointerMove = (event) => this.drag(event);
    this.onPointerUp = (event) => this.endDrag(event);
    this.onDoubleClick = () => this.reset();

    this.onKeydown = (event) => {
      if (this.dragging && event.key === "Escape") {
        this.cancelDrag();
        return;
      }

      const step = event.shiftKey ? 96 : 24;
      const height = this.shellHeight();

      const resize = (px) => {
        event.preventDefault();
        this.apply(this.clamp(px, height));
        this.persist(px);
        this.graphResize();
      };

      switch (event.key) {
        case "ArrowUp":
          resize(this.current() - step);
          break;
        case "ArrowDown":
          resize(this.current() + step);
          break;
        case "Home":
          resize(this.min);
          break;
        case "End":
          resize(Math.round(height * 0.9));
          break;
        case "Enter":
        case " ":
          event.preventDefault();
          this.reset();
          break;
      }
    };

    this.el.addEventListener("pointerdown", this.onPointerDown);
    this.el.addEventListener("dblclick", this.onDoubleClick);
    this.el.addEventListener("keydown", this.onKeydown);
    window.addEventListener("pointermove", this.onPointerMove);
    window.addEventListener("pointerup", this.onPointerUp);
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onPointerDown);
    this.el.removeEventListener("dblclick", this.onDoubleClick);
    this.el.removeEventListener("keydown", this.onKeydown);
    window.removeEventListener("pointermove", this.onPointerMove);
    window.removeEventListener("pointerup", this.onPointerUp);
  },

  // --- internals ---------------------------------------------------------------

  startDrag(event) {
    if (event.button !== 0) return;
    event.preventDefault();
    this.dragging = true;
    this.preDrag = this.current();
    this.el.setPointerCapture?.(event.pointerId);
    document.body.style.cursor = "row-resize";
    document.body.style.userSelect = "none";
  },

  drag(event) {
    if (!this.dragging) return;
    // One style write per frame; no reads in this path.
    if (this.raf) return;
    this.raf = requestAnimationFrame(() => {
      this.raf = null;
      if (!this.dragging) return;
      this.apply(this.clamp(this.pointerRow(event), this.shellHeight()));
    });
  },

  endDrag() {
    if (!this.dragging) return;
    this.dragging = false;
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
    const px = this.current();
    this.persist(px);
    // Relayout-ish work happens here and only here: one buffer resize.
    this.graphResize();
  },

  cancelDrag() {
    this.dragging = false;
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
    this.apply(this.preDrag);
    this.persist(this.preDrag);
  },

  reset() {
    localStorage.removeItem(this.key);
    this.shell.style.removeProperty("grid-template-rows");
    this.graphResize();
  },

  pointerRow(event) {
    const box = this.shell.getBoundingClientRect();
    return Math.round(event.clientY - box.top);
  },

  shellHeight() {
    return Math.round(this.shell.getBoundingClientRect().height);
  },

  clamp(px, shellHeight) {
    const max = Math.max(this.min + 40, shellHeight - 96);
    return String(Math.min(Math.max(Math.round(px), this.min), max));
  },

  // The first track is the pane; the divider and the rest keep their
  // stylesheet sizes — we only ever replace the leading length.
  apply(px) {
    const tracks = getComputedStyle(this.shell).gridTemplateRows.split(" ");
    tracks[0] = `${px}px`;
    this.shell.style.gridTemplateRows = tracks.join(" ");
  },

  rows() {
    return getComputedStyle(this.shell).gridTemplateRows;
  },

  current() {
    return parseInt(this.rows().split(" ")[0], 10) || 0;
  },

  persist(px) {
    try {
      localStorage.setItem(this.key, String(px));
    } catch {
      /* private mode: layout just does not persist */
    }
  },

  restore() {
    let stored = null;
    try {
      stored = localStorage.getItem(this.key);
    } catch {
      stored = null;
    }
    if (stored && parseInt(stored, 10) >= this.min) {
      this.apply(parseInt(stored, 10));
    }
  },

  // The graph element exposes its live Cytoscape instance for exactly this
  // kind of console-level use; resize() redraws buffers into the new box.
  // The element's own ResizeObserver keeps it fresh during the drag; this
  // is the explicit end-of-gesture settle.
  graphResize() {
    const graph = this.shell.querySelector("ash-canvas-graph");
    if (graph && graph.cy && typeof graph.cy.resize === "function") {
      graph.cy.resize();
    }
  },
};

export default CanvasSplitter;
