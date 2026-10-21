// <atlas-modal> and <atlas-drawer>: Atlas Overlays (Figma page "Overlays",
// sets Modal 58c8a9e6… and Drawer 30072d95…), on the native <dialog>.
//
//   <atlas-modal id="award" data-title="Award this project">
//     <p>Awarding sends the vendor a confirmation…</p>
//     <button slot="footer" …>Cancel</button>
//     <button slot="footer" …>Award project</button>
//   </atlas-modal>
//
// The browser does the hard parts: showModal() puts the dialog in the top
// layer, makes the page behind it inert (focus stays inside), closes it on
// Escape and returns focus to what opened it. This adds the Atlas frame,
// backdrop click, scroll lock and drawer motion.
//
// Content is slotted, so it stays in the page's light DOM: HEEx forms inside
// keep phx-change, phx-submit and LiveViewTest's form/3 as usual.
//
// Opening and closing, with no round trip or from the server:
//   JS.dispatch("atlas:open", to: "#award") / JS.dispatch("atlas:close", …)
//   push_event(socket, "atlas:open", %{id: "award"}) / "atlas:close"
// The element dispatches "atlas:closed" (bubbling) when it closes.
//
// Figma notes kept here: only the drawer body scrolls (header and footer are
// fixed with 1px rules); layering (z-index) is unsolved in Atlas, and the top
// layer makes it moot for these two. The accessible name comes from
// data-title, rendered inside the shadow root: a heading in the slotted
// content could not be referenced across the shadow boundary. Without
// data-title (content that brings its own heading, like A2UI prompts) the
// header is just the close button, and the name is copied from the first
// heading in the content when the dialog opens.

import {LitElement, html, css, nothing} from "lit"

let instances = 0

const HEADINGS = "h1, h2, h3, h4, h5, h6"

// The first heading in the slotted content, looking through nested shadow
// roots too: A2UI renders a prompt's title as an <h3> inside its Column's and
// Text's shadow roots.
function findHeading(root) {
  const direct = root.querySelector(HEADINGS)
  if (direct) return direct
  for (const el of root.querySelectorAll("*")) {
    if (el.shadowRoot) {
      const found = findHeading(el.shadowRoot)
      if (found) return found
    }
  }
  return null
}
let openCount = 0

const frame = css`
  :host {
    display: contents;
  }
  dialog {
    border: 0;
    padding: 0;
    color: var(--atlas-text-primary);
    background: var(--atlas-bg-surface);
    font-family: var(--atlas-font-family-sans);
    overflow: hidden;
  }
  dialog[open] {
    display: flex;
    flex-direction: column;
  }
  dialog.untitled .body {
    padding-top: var(--atlas-spacing-24);
    padding-right: calc(var(--atlas-spacing-24) + 32px); /* clear of the close button */
  }
  dialog::backdrop {
    background: var(--atlas-bg-scrim);
  }
  header.close-only {
    position: absolute;
    top: 0;
    right: 0;
  }
  header {
    display: flex;
    align-items: flex-start;
    gap: var(--atlas-spacing-16);
    padding: var(--atlas-spacing-24) var(--atlas-spacing-24) var(--atlas-spacing-16);
  }
  h2 {
    flex: 1;
    min-width: 0;
    margin: 0;
    font-size: var(--atlas-font-size-lg);
    line-height: 24px;
    font-weight: var(--atlas-font-weight-semibold);
    overflow-wrap: anywhere; /* Bilingual rule: titles wrap, never truncate */
  }
  .close {
    /* 32px target around the 20px icon; the negative margin keeps the icon
       where Figma puts it (24px from the top and right edges). */
    flex: none;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    margin: -6px -6px 0 0;
    padding: 0;
    border: 0;
    border-radius: var(--atlas-radius-default);
    background: transparent;
    color: var(--atlas-icon-subtle);
    cursor: pointer;
  }
  .close:hover {
    background: var(--atlas-bg-surface-sunken);
  }
  .close:focus-visible {
    outline: var(--atlas-focus-width) solid var(--atlas-border-focus);
    outline-offset: var(--atlas-focus-offset);
  }
  .body {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding: 0 var(--atlas-spacing-24) var(--atlas-spacing-24);
    font-size: var(--atlas-font-size-sm);
    line-height: 20px;
    color: var(--atlas-text-secondary);
  }
  footer {
    display: flex;
    flex-wrap: wrap; /* Bilingual rule: buttons grow, the row wraps */
    gap: var(--atlas-spacing-12);
    padding: 0 var(--atlas-spacing-24) var(--atlas-spacing-24);
  }
  footer[hidden] {
    display: none;
  }
`

class AtlasDialogBase extends LitElement {
  static properties = {
    size: {reflect: true},
    heading: {attribute: "data-title"},
    closeLabel: {attribute: "data-close-label"},
    hasFooter: {state: true},
  }

  constructor() {
    super()
    this.uid = `atlas-dialog-${++instances}`
    this.closeLabel = "Close"
    this.hasFooter = false
    this.addEventListener("atlas:open", () => this.show())
    this.addEventListener("atlas:close", () => this.close())
  }

  get dialog() {
    return this.renderRoot.querySelector("dialog")
  }

  get open() {
    return Boolean(this.dialog?.open)
  }

  show() {
    if (!this.dialog || this.dialog.open) return
    if (!this.heading) {
      const heading = findHeading(this)
      this.dialog.setAttribute("aria-label", heading?.textContent.trim() || this.closeLabel)
    }
    this.dialog.showModal()
    // Scroll lock: the page behind is inert, it shouldn't scroll either.
    if (openCount++ === 0) document.documentElement.style.overflow = "hidden"
  }

  close() {
    if (this.dialog?.open) this.dialog.close()
  }

  onClosed() {
    if (--openCount === 0) document.documentElement.style.overflow = ""
    this.dispatchEvent(new Event("atlas:closed", {bubbles: true, composed: true}))
  }

  // A click on the dialog element itself, outside its box, is the backdrop.
  onClick(event) {
    if (event.target !== this.dialog) return
    const box = this.dialog.getBoundingClientRect()
    const inside =
      event.clientX >= box.left && event.clientX <= box.right && event.clientY >= box.top && event.clientY <= box.bottom
    if (!inside) this.close()
  }

  disconnectedCallback() {
    if (this.open) this.dialog.close()
    super.disconnectedCallback()
  }

  render() {
    const id = this.uid
    const titled = Boolean(this.heading)
    return html`<dialog
      part="dialog"
      class=${titled ? "" : "untitled"}
      aria-labelledby=${titled ? `${id}-title` : nothing}
      @click=${this.onClick}
      @close=${this.onClosed}
    >
      <header class=${titled ? "" : "close-only"}>
        ${titled ? html`<h2 id="${id}-title">${this.heading}</h2>` : nothing}
        <button type="button" class="close" aria-label=${this.closeLabel} @click=${() => this.close()}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
            stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line>
          </svg>
        </button>
      </header>
      <div class="body"><slot></slot></div>
      <footer ?hidden=${!this.hasFooter}>
        <slot name="footer" @slotchange=${(e) => (this.hasFooter = e.target.assignedElements().length > 0)}></slot>
      </footer>
    </dialog>`
  }
}

// Modal (Figma: size=default 540px wide, radius/lg, elevation/lg; size=fullscreen
// covers the screen with no radius). Footer buttons align to the end.
export class AtlasModal extends AtlasDialogBase {
  static styles = [
    frame,
    css`
      dialog {
        width: min(540px, calc(100vw - 2 * var(--atlas-spacing-16)));
        max-height: calc(100dvh - 2 * var(--atlas-spacing-32));
        border-radius: var(--atlas-radius-lg);
        box-shadow: var(--atlas-elevation-lg);
      }
      :host([size="fullscreen"]) dialog {
        width: 100vw;
        height: 100dvh;
        max-width: none;
        max-height: none;
        border-radius: 0;
      }
      footer {
        justify-content: flex-end;
      }
      @media (prefers-reduced-motion: no-preference) {
        dialog[open] {
          animation: atlas-modal-in 150ms ease-out;
        }
      }
      @keyframes atlas-modal-in {
        from {
          opacity: 0;
          transform: translateY(8px);
        }
      }
    `,
  ]

  constructor() {
    super()
    this.size = "default"
  }
}

// Drawer (Figma: size=half 512px, size=full the whole screen; full height,
// elevation/2xl, no radius). Header and footer are fixed with 1px rules and
// only the body scrolls. Footer: secondary at the start, primary at the end.
export class AtlasDrawer extends AtlasDialogBase {
  static styles = [
    frame,
    css`
      dialog {
        margin: 0 0 0 auto;
        width: min(512px, 100vw);
        height: 100dvh;
        max-width: none;
        max-height: none;
        border-radius: 0;
        box-shadow: var(--atlas-elevation-2xl);
      }
      :host([size="full"]) dialog {
        width: 100vw;
      }
      header {
        padding-bottom: var(--atlas-spacing-24);
        border-bottom: var(--atlas-border-width-1) solid var(--atlas-border-default);
      }
      .body {
        padding: var(--atlas-spacing-24);
      }
      footer {
        justify-content: space-between;
        padding: var(--atlas-spacing-24);
        border-top: var(--atlas-border-width-1) solid var(--atlas-border-default);
      }
      @media (prefers-reduced-motion: no-preference) {
        dialog[open] {
          animation: atlas-drawer-in 200ms ease-out;
        }
      }
      @keyframes atlas-drawer-in {
        from {
          transform: translateX(100%);
        }
      }
    `,
  ]

  constructor() {
    super()
    this.size = "half"
  }
}

// Server-driven open/close: push_event(socket, "atlas:open" | "atlas:close", %{id: "…"}).
// LiveView delivers push_event payloads as window events named "phx:<event>".
for (const action of ["open", "close"]) {
  window.addEventListener(`phx:atlas:${action}`, (event) => {
    const el = document.getElementById(event.detail?.id)
    if (el && typeof el[action === "open" ? "show" : "close"] === "function") {
      el[action === "open" ? "show" : "close"]()
    }
  })
}
