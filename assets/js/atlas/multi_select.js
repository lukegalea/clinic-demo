// <atlas-multi-select>: pick several options from a list, in a LiveView form.
//
//   <atlas-multi-select id="lab-properties" name="lab[properties][]"
//     data-label="Properties" data-options='[{"value":"a","label":"A"}]'
//     data-value='["a"]' data-error="…" required></atlas-multi-select>
//
// Accessibility: the WAI-ARIA combobox pattern with a multi-select listbox.
// The text input filters the options; ArrowUp/Down move the active option,
// Enter toggles it, Escape closes, Backspace on an empty input removes the
// last choice. Each choice shows as a tag with its own Remove button, and a
// status line announces how many are selected.
//
// LiveView rules from the POC (guidance doc, section 4):
//   * styles live in the shadow root, never on the host (rule 1), so the
//     element needs no phx-update="ignore";
//   * server-owned state arrives as data-* attributes (rule 2);
//   * `form`, `validity` and `willValidate` getters (rule 3);
//   * the host re-dispatches `input` when the choice changes, and the filter
//     input's own events are stopped (rule 4).
// It submits one entry per choice under `name` (end it with "[]"), and one
// empty entry when nothing is chosen, so the server always sees the field.
//
// Strings default to English; pass data-* overrides for French. The Atlas
// Bilingual page has no pairs for these, so none are invented here.

import {LitElement, html, css, nothing} from "lit"
import {classes} from "./recipe.js"
import {field} from "./input.recipe.js"
import {tag} from "./tag.recipe.js"
import {atlasSheet} from "./stylesheet.js"

const json = (fallback) => ({
  fromAttribute(text) {
    try {
      return JSON.parse(text) ?? fallback
    } catch {
      return fallback
    }
  },
})

let instances = 0

export class AtlasMultiSelect extends LitElement {
  static formAssociated = true
  static shadowRootOptions = {...LitElement.shadowRootOptions, delegatesFocus: true}

  static properties = {
    name: {},
    required: {type: Boolean},
    label: {attribute: "data-label"},
    caption: {attribute: "data-caption"},
    error: {attribute: "data-error"},
    placeholder: {attribute: "data-placeholder"},
    removeLabel: {attribute: "data-remove-label"},
    noResults: {attribute: "data-no-results"},
    selectedLabel: {attribute: "data-selected-label"},
    options: {attribute: "data-options", converter: json([])},
    value: {attribute: "data-value", converter: json([])},
    open: {state: true},
    query: {state: true},
    active: {state: true},
  }

  static styles = css`
    :host {
      display: block;
    }
  `

  constructor() {
    super()
    this.internals = this.attachInternals()
    this.uid = `atlas-ms-${++instances}`
    this.options = []
    this.value = []
    this.open = false
    this.query = ""
    this.active = -1
    this.removeLabel = "Remove"
    this.noResults = "No matches"
    this.selectedLabel = "selected"
    this.placeholder = "Search"
    this.onOutside = (event) => {
      if (this.open && !event.composedPath().includes(this)) this.close()
    }
  }

  // The form-associated surface LiveView needs (rule 3).
  get form() {
    return this.internals.form
  }
  get validity() {
    return this.internals.validity
  }
  get willValidate() {
    return this.internals.willValidate
  }

  connectedCallback() {
    super.connectedCallback()
    const sheet = atlasSheet()
    if (sheet && !this.renderRoot.adoptedStyleSheets.includes(sheet)) {
      this.renderRoot.adoptedStyleSheets = [...this.renderRoot.adoptedStyleSheets, sheet]
    }
    document.addEventListener("pointerdown", this.onOutside)
  }

  disconnectedCallback() {
    document.removeEventListener("pointerdown", this.onOutside)
    super.disconnectedCallback()
  }

  formResetCallback() {
    this.value = []
  }

  // Server-owned value changes (data-value) don't clobber a choice the user is
  // making: while focus is inside, the local choice wins.
  shouldUpdate(changed) {
    if (changed.has("value") && this.matches(":focus-within") && this.localValue) {
      this.value = this.localValue
    }
    return true
  }

  willUpdate(changed) {
    if (changed.has("value")) this.syncForm()
  }

  updated() {
    this.syncValidity()
  }

  get selected() {
    const chosen = new Set(this.value)
    return this.options.filter((option) => chosen.has(option.value))
  }

  get visible() {
    const query = this.query.trim().toLocaleLowerCase()
    return query
      ? this.options.filter((option) => option.label.toLocaleLowerCase().includes(query))
      : this.options
  }

  syncForm() {
    const data = new FormData()
    const values = this.value.length ? this.value : [""]
    for (const value of values) data.append(this.name, value)
    this.internals.setFormValue(data)
  }

  syncValidity() {
    const input = this.renderRoot.querySelector("input")
    const missing = this.required && this.value.length === 0
    this.internals.setValidity(missing ? {valueMissing: true} : {}, missing ? "Choose at least one option" : "", input)
  }

  // Picking from the list clears the filter so the next choice starts from the
  // whole list, with the picked option still active.
  pick(option) {
    this.toggle(option.value)
    this.query = ""
    this.active = this.options.indexOf(option)
  }

  toggle(value) {
    this.value = this.value.includes(value)
      ? this.value.filter((chosen) => chosen !== value)
      : [...this.value, value]
    this.localValue = this.value
    this.syncForm()
    // Rule 4: the choice changed, so the host tells LiveView.
    this.dispatchEvent(new Event("input", {bubbles: true}))
    this.dispatchEvent(new Event("change", {bubbles: true}))
  }

  close() {
    this.open = false
    this.active = -1
    this.query = ""
  }

  onFilter(event) {
    event.stopPropagation() // typing to filter is not a change of the field
    this.query = event.target.value
    this.open = true
    this.active = this.visible.length ? 0 : -1
  }

  onKeydown(event) {
    const visible = this.visible
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        this.open = true
        this.active = Math.min(this.active + 1, visible.length - 1)
        break
      case "ArrowUp":
        event.preventDefault()
        this.open = true
        this.active = Math.max(this.active - 1, 0)
        break
      case "Enter":
        if (this.open && visible[this.active]) {
          event.preventDefault()
          this.pick(visible[this.active])
        }
        break
      case "Escape":
        if (this.open) {
          event.preventDefault()
          this.close()
        }
        break
      case "Backspace":
        if (this.query === "" && this.value.length) this.toggle(this.value.at(-1))
        break
      case "Tab":
        this.close()
        break
    }
  }

  optionId(option) {
    return `${this.uid}-opt-${this.options.indexOf(option)}`
  }

  render() {
    const id = this.uid
    const visible = this.visible
    const selected = this.selected
    const invalid = Boolean(this.error)
    const activeOption = this.open ? visible[this.active] : undefined
    const describedby = [this.caption && `${id}-caption`, invalid && `${id}-error`].filter(Boolean).join(" ")
    const part = (p) => classes(field, {part: p})
    const chip = classes(tag, {color: "blue", size: "sm"})

    return html`<div class=${part("root")} data-atlas="MultiSelect">
      <label id="${id}-label" for="${id}-input" class=${part("label")}>${this.label}${this.required
        ? html`<span class=${part("required")} aria-hidden="true"> *</span>`
        : nothing}</label>

      <!-- The list is anchored to the box, not the field: the caption and error
           below it come and go, and must not move the list under the pointer. -->
      <div class="relative">
      <div
        class="flex flex-wrap items-center gap-1 min-h-[34px] px-2 py-1 rounded-(--atlas-radius-lg) border bg-(--atlas-bg-surface) cursor-text focus-within:outline-(length:--atlas-focus-width) focus-within:outline-offset-(length:--atlas-focus-offset) focus-within:outline-(--atlas-border-focus) focus-within:outline-solid ${invalid
          ? "border-(--atlas-border-danger)"
          : "border-(--atlas-border-strong)"}"
        @click=${() => this.renderRoot.querySelector("input")?.focus()}
      >
        ${selected.map(
          (option) => html`<span class=${chip}>
            ${option.label}
            <button
              type="button"
              class="inline-flex items-center justify-center size-6 -me-1 rounded-(--atlas-radius-full) hover:bg-(--atlas-bg-surface) focus-visible:outline-(length:--atlas-focus-width) focus-visible:outline-(--atlas-border-focus) focus-visible:outline-solid"
              aria-label="${this.removeLabel} ${option.label}"
              @click=${(event) => {
                event.stopPropagation()
                this.toggle(option.value)
                this.renderRoot.querySelector("input")?.focus()
              }}
            >
              <span aria-hidden="true">×</span>
            </button>
          </span>`,
        )}
        <input
          id="${id}-input"
          class="flex-1 min-w-24 h-6 bg-transparent text-sm text-(--atlas-text-primary) placeholder:text-(--atlas-text-placeholder) outline-none"
          role="combobox"
          autocomplete="off"
          aria-autocomplete="list"
          aria-expanded=${this.open ? "true" : "false"}
          aria-controls="${id}-listbox"
          aria-activedescendant=${activeOption ? this.optionId(activeOption) : nothing}
          aria-required=${this.required ? "true" : nothing}
          aria-invalid=${invalid ? "true" : nothing}
          aria-describedby=${describedby || nothing}
          placeholder=${selected.length ? "" : this.placeholder}
          .value=${this.query}
          @input=${this.onFilter}
          @keydown=${this.onKeydown}
          @focus=${() => (this.open = true)}
        />
      </div>

      <ul
        id="${id}-listbox"
        role="listbox"
        aria-multiselectable="true"
        aria-labelledby="${id}-label"
        ?hidden=${!this.open}
        class="absolute z-20 inset-x-0 top-full mt-1 max-h-60 overflow-auto py-1 rounded-(--atlas-radius-lg) border border-(--atlas-border-default) bg-(--atlas-bg-surface) shadow-(--atlas-elevation-md) text-sm"
      >
        ${visible.length
          ? visible.map((option, index) => {
              const isSelected = this.value.includes(option.value)
              return html`<li
                id=${this.optionId(option)}
                role="option"
                aria-selected=${isSelected ? "true" : "false"}
                class="flex items-center gap-2 min-h-9 px-3 cursor-pointer ${index === this.active
                  ? "bg-(--atlas-bg-surface-sunken)"
                  : ""}"
                @mousedown=${(event) => event.preventDefault()}
                @mouseenter=${() => (this.active = index)}
                @click=${() => this.pick(option)}
              >
                <span
                  aria-hidden="true"
                  class="inline-flex items-center justify-center size-4 rounded-(--atlas-radius-default) border text-xs ${isSelected
                    ? "bg-(--atlas-bg-brand) border-(--atlas-border-brand) text-(--atlas-text-on-brand)"
                    : "border-(--atlas-border-strong)"}"
                  >${isSelected ? "✓" : ""}</span
                >
                ${option.label}
              </li>`
            })
          : html`<li role="presentation" class="px-3 py-2 text-(--atlas-text-secondary)">${this.noResults}</li>`}
      </ul>
      </div>

      <p role="status" class="sr-only">${selected.length} ${this.selectedLabel}</p>
      ${this.caption ? html`<p id="${id}-caption" class=${part("caption")}>${this.caption}</p>` : nothing}
      ${invalid ? html`<p id="${id}-error" class=${part("error")}>${this.error}</p>` : nothing}
    </div>`
  }
}
