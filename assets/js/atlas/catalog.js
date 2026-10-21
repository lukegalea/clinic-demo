// The Atlas A2UI catalog adapter (POC).
//
// `withAtlas(catalog, deps)` returns a copy of an existing A2UI catalog, under
// the same id, with component types swapped for Atlas elements. The wire
// format does not change: the server still emits basic-catalog components,
// and the adapter only decides which element draws them.
//
// Each swap is one entry in SWAPS: the A2UI component type, the Atlas tag,
// and how to define the element given the catalog's current entry for that
// type (so an Atlas element can subclass whatever it replaces, the way
// ash_a2ui's own catalogs do). Applied to both catalogs in app.js: the merged
// basic catalog (Button, Row) and the admin catalog (ChoicePicker).

import {button} from "./button.recipe.js"
import {classes, tag} from "./recipe.js"
import {adoptAtlasStyles} from "./stylesheet.js"

// A2UI's three Button variants, mapped onto Atlas Button variants.
const A2UI_BUTTON_VARIANTS = {default: "secondary", primary: "primary", borderless: "link"}

function defineButton(tagName, {A2uiLitElement, lit}, api) {
  const {html, nothing} = lit

  return class AtlasButton extends A2uiLitElement {
    constructor() {
      super()
      this.api = api
    }

    // Light DOM: the native <button> is a direct child, so labels, forms and
    // Tailwind classes behave as they do anywhere else on the page.
    createRenderRoot() {
      return this
    }

    connectedCallback() {
      super.connectedCallback()
      adoptAtlasStyles(this)
    }

    render() {
      const props = this.controller.props
      if (!props) return nothing
      const disabled = props.isValid === false
      const atlas = {variant: A2UI_BUTTON_VARIANTS[props.variant ?? "default"], size: "md"}

      return html`<button
        type="button"
        class=${classes(button, atlas)}
        data-atlas=${tag(button, atlas)}
        ?disabled=${disabled}
        @click=${() => !disabled && props.action?.()}
      >${props.child ? this.renderNode(props.child) : nothing}</button>`
    }
  }
}

// Atlas Filter pattern (Patterns page): the controls of a filter bar sit on
// one baseline, bottom-aligned under their labels, and wrap when French
// labels or a narrow screen run out of room. The server does not yet send
// `align` for query-control rows (ash_a2ui ids them `query_controls_body`, or
// `query_<table>_controls_body` on a surface with several tables),
// so the pattern is applied by id until the encoder emits `align: "end"`;
// a row that does carry `align`/`justify` keeps the stock behaviour.
const FILTER_ROW = /^query_(?:.+_)?controls_body$/

function defineRow(_tagName, _deps, _api, Stock) {
  return class AtlasRow extends Stock {
    updated(changed) {
      super.updated(changed)
      const props = this.controller?.props
      const id = this.context?.componentModel?.id ?? ""
      const filter = props && !props.align && FILTER_ROW.test(id)
      this.style.alignItems = filter ? "flex-end" : this.style.alignItems
      this.style.flexWrap = filter ? "wrap" : ""
      if (filter) this.dataset.atlas = "Pattern/Filter"
    }
  }
}

// Atlas Select (input family): truncates rather than grows (Bilingual page),
// so it needs a sensible minimum width and room for its chevron. The admin
// choicepicker renders in shadow DOM; its styles are extended, not replaced.
function defineChoicePicker(_tagName, {lit}, _api, Stock) {
  const {css} = lit

  return class AtlasChoicePicker extends Stock {
    static styles = [
      ...[Stock.styles].flat(),
      css`
        select.control {
          min-width: 7.5rem;
          max-width: 100%;
          padding-right: calc(var(--atlas-spacing-12) + 1.25rem);
          text-overflow: ellipsis;
          background-position:
            calc(100% - var(--atlas-spacing-16) - 0.35rem) calc(50% + 0.1rem),
            calc(100% - var(--atlas-spacing-16)) calc(50% + 0.1rem);
        }
        select.control:focus-visible {
          outline: var(--atlas-focus-width) solid var(--atlas-border-focus);
          outline-offset: var(--atlas-focus-offset);
        }
      `,
    ]
  }
}

// Admin DataGrid: a row action shows a spinner until the surface's data model
// writes an outcome (/ui/feedback/message or /ui/response). `view_record` and
// `start_edit` write neither as a CHANGE: they reset an already-empty feedback
// message to "", and the data model's signals only notify on change, so the
// spinner never clears. Opening a record task always changes /ui/intent and
// /ui/panel, so those settle the row action too. POC workaround; the real fix
// belongs in ash_a2ui (settle on those paths, or write a response).
const TASK_PATHS = ["/ui/intent", "/ui/panel"]

function defineDataGrid(_tagName, _deps, _api, Stock) {
  return class AtlasDataGrid extends Stock {
    // Date-only cells: see localDate below.
    cellValue(row, column) {
      const value = String(column.path).split("/").reduce((obj, key) => obj?.[key], row)
      const date = (!column.format || DATE_FORMATS.has(column.format)) && localDate(value)
      return date || super.cellValue(row, column)
    }

    onRowAction(action, index) {
      super.onRowAction(action, index)
      if (this._amBusyRowAction) this.watchTaskSettle()
    }

    watchTaskSettle() {
      const dataModel = this.surface?.dataModel
      if (this._atlasTaskSubs || typeof dataModel?.subscribe !== "function") return
      this._atlasTaskSubs = TASK_PATHS.map((path) => dataModel.subscribe(path, () => this.settleTask()))
    }

    settleTask() {
      for (const sub of this._atlasTaskSubs || []) sub.unsubscribe?.()
      this._atlasTaskSubs = null
      if (!this._amBusyRowAction) return
      // Drop the stock outcome subscriptions too, so the next click re-arms them.
      for (const sub of this._amSettleUnsubscribes || []) sub.unsubscribe?.()
      this._amSettleUnsubscribes = null
      this.onActionSettled()
      this.requestUpdate()
    }

    disconnectedCallback() {
      for (const sub of this._atlasTaskSubs || []) sub.unsubscribe?.()
      this._atlasTaskSubs = null
      super.disconnectedCallback()
    }
  }
}

// Admin FieldDisplay (detail cards, view panels): same date-only fix as the
// grid's cells. Everything else renders as stock.
function defineFieldDisplay(_tagName, {lit}, _api, Stock) {
  return class AtlasFieldDisplay extends Stock {
    render() {
      const props = this.controller?.props
      const date = props && !props.link && DATE_FORMATS.has(props.format) && localDate(props.value)
      if (!date) return super.render()
      return lit.html`
        <div class="field">
          <dt class="field-label">${props.label ?? ""}</dt>
          <dd class="field-value">${date}</dd>
        </div>
      `
    }
  }
}

// ash_a2ui's formatDisplayValue turns "2026-12-31" into Date.UTC(...) and then
// formats it in local time, so west of Greenwich every date shows a day early
// (Dec 30). A date has no time zone: build it at local midnight. Returns null
// for anything that is not a date-only string. POC workaround; the real fix
// belongs in ash_admin_tokens.js (format with timeZone: "UTC", or build local).
const dateOnlyFormatter = new Intl.DateTimeFormat(undefined, {dateStyle: "medium"})

function localDate(value) {
  if (typeof value !== "string" || !DATE_ONLY.test(value)) return null
  const [year, month, day] = value.split("-").map(Number)
  return dateOnlyFormatter.format(new Date(year, month - 1, day))
}

// Admin EntityPage: renders the surface title as the page's <h1>. When the
// HEEx shell around the surface already owns the page heading (it marks its
// container `data-atlas-shell-title`), a second <h1> is both a duplicate and
// an outline error, so the surface's header is left out. Elsewhere: stock.
function defineEntityPage(_tagName, {lit}, _api, Stock) {
  const {css} = lit
  return class AtlasEntityPage extends Stock {
    static styles = [
      ...[Stock.styles ?? []].flat(),
      css`
        :host([data-shell-title]) .page-header {
          display: none;
        }
      `,
    ]

    connectedCallback() {
      super.connectedCallback()
      const host = this.getRootNode()?.host
      this.toggleAttribute("data-shell-title", Boolean(host?.closest?.("[data-atlas-shell-title]")))
    }
  }
}

// A2UI Modal: the stock one is a <div role="dialog"> over a z-index 1000
// overlay, with no Escape, no focus containment, no focus return and no
// accessible name. Rendering it through <atlas-modal> (the native <dialog>)
// gives declared screens the same modal as hand-built pages. The trigger and
// content still come from the A2UI component tree; isOpen/openModal/closeModal
// are the stock element's own state.
// One deliberate change: the modal closes when its prompt succeeds, so a
// Confirm ends the task. The signal is the server resetting the prompt's
// /prompt/values/<action> to {} (ActionHandler does that only after a
// successful prompt invoke; v0.9.1 leaves no success /ui/feedback for it). The
// stock modal stays open after a successful correction (checked with
// ?atlas=off on the contract page). POC behaviour; the fix belongs upstream.
function defineModal(_tagName, {lit}, _api, Stock) {
  const {html, nothing} = lit
  return class AtlasA2uiModal extends Stock {
    render() {
      const props = this.controller?.props
      if (!props) return nothing
      return html`
        <div class="a2ui-modal-trigger" @click=${() => this.openModal()}>
          ${props.trigger ? this.renderNode(props.trigger) : nothing}
        </div>
        <atlas-modal @atlas:closed=${() => this.closeModal()}>
          ${this.isOpen && props.content ? this.renderNode(props.content) : nothing}
        </atlas-modal>
      `
    }

    updated(changed) {
      super.updated?.(changed)
      const modal = this.renderRoot.querySelector("atlas-modal")
      if (!modal) return
      if (this.isOpen && !modal.open) {
        customElements.whenDefined("atlas-modal").then(() => modal.updateComplete).then(() => modal.show())
        this.watchOutcome()
      } else if (!this.isOpen && modal.open) {
        modal.close()
      }
      if (!this.isOpen) this.stopWatching()
    }

    watchOutcome() {
      const dataModel = this.context?.dataContext?.dataModel
      if (this._atlasOutcome || typeof dataModel?.subscribe !== "function") return
      const snapshot = (values) => JSON.parse(JSON.stringify(values || {}))
      // The server's reset replaces the action's values with {} (no keys); a
      // user emptying a field leaves {field: ""}, which must not close it.
      const filled = (values) => values != null && typeof values === "object" && Object.keys(values).length > 0
      let previous = snapshot(dataModel.get("/prompt/values"))
      this._atlasOutcome = dataModel.subscribe("/prompt/values", (values) => {
        const now = snapshot(values)
        const cleared = Object.keys(now).some((action) => !filled(now[action]) && filled(previous[action]))
        previous = now
        if (cleared) this.closeModal()
      })
    }

    stopWatching() {
      this._atlasOutcome?.unsubscribe?.()
      this._atlasOutcome = null
    }

    disconnectedCallback() {
      this.stopWatching()
      super.disconnectedCallback()
    }
  }
}

const SWAPS = [
  {type: "Button", tagName: "atlas-button", define: defineButton},
  {type: "Row", tagName: "atlas-row", define: defineRow},
  // The admin catalog's picker only: the merged catalog's native-select picker
  // is a different element and is not used on admin surfaces.
  {type: "ChoicePicker", tagName: "atlas-choicepicker", define: defineChoicePicker,
   when: (stockTag) => stockTag === "ash-admin-choicepicker"},
  {type: "dataGrid", tagName: "atlas-data-grid", define: defineDataGrid},
  {type: "fieldDisplay", tagName: "atlas-field-display", define: defineFieldDisplay},
  {type: "entityPage", tagName: "atlas-entity-page", define: defineEntityPage},
  {type: "Modal", tagName: "atlas-a2ui-modal", define: defineModal},
]

export function withAtlas(catalog, deps) {
  const {Catalog} = deps
  const swaps = new Map()

  for (const {type, tagName, define, when} of SWAPS) {
    const current = catalog.components.get(type)
    if (!current) continue
    if (when && !when(current.tagName)) continue
    // Already an Atlas element (the admin catalog inherits our Button and Row).
    if (current.tagName.startsWith("atlas-")) continue
    // Only one Atlas element per type: the first catalog that offers it wins.
    if (!customElements.get(tagName)) {
      const Stock = customElements.get(current.tagName)
      if (!Stock) continue
      customElements.define(tagName, define(tagName, deps, current, Stock))
    }
    swaps.set(type, {...current, tagName})
  }

  const components = [...catalog.components.values()].map((c) => swaps.get(c.name) || c)
  const functions = [...catalog.functions.values()].map((f) => FUNCTION_FIXES[f.name]?.(f) || f)
  return new Catalog(catalog.id, components, functions, catalog.themeSchema)
}

// Function fixes, until upstream has them.
//
// formatDate: web_core parses a date-only ISO string ("2026-12-31") with
// `new Date(value)`, which reads it as midnight UTC, then formats it in local
// time, so every date west of Greenwich shows a day early (Dec 30). A date has
// no time zone: read it as local midnight instead. Timestamps pass through.
const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/
const DATE_FORMATS = new Set(["date", "datetime"])

const FUNCTION_FIXES = {
  formatDate: (stock) => ({
    ...stock,
    execute(args, ...rest) {
      const value = typeof args.value === "string" && DATE_ONLY.test(args.value)
        ? `${args.value}T00:00:00`
        : args.value
      return stock.execute.call(this, {...args, value}, ...rest)
    },
  }),
}
