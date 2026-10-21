// Atlas elements for HEEx pages (outside A2UI surfaces).
//
// <atlas-tag color="gold" size="sm">Pending</atlas-tag>
//
// The label stays light-DOM text the server sent, slotted into a shadow root
// that carries the recipe's classes. It must not style its own host: inside
// LiveView content, every patch resets the host's `class` to what the server
// rendered (none), which is what the POC's storybook caught. The shadow root
// adopts the page's compiled Atlas stylesheet, as A2UI surfaces do.
// Until the bundle defines the element, the label shows unstyled; that gap
// is what `atlas-*:not(:defined)` rules and HEEx twins exist to cover.

import {LitElement, css, html, nothing} from "lit"
import {tag} from "./tag.recipe.js"
import {field, input} from "./input.recipe.js"
import {classes, tag as atlasTag} from "./recipe.js"
import {atlasSheet} from "./stylesheet.js"
import {AtlasMultiSelect} from "./multi_select.js"
import {AtlasModal, AtlasDrawer} from "./dialog.js"

class AtlasTag extends LitElement {
  static properties = {color: {reflect: true}, size: {reflect: true}}
  static styles = css`
    :host {
      display: inline-flex;
    }
  `

  connectedCallback() {
    super.connectedCallback()
    const sheet = atlasSheet()
    if (sheet && !this.renderRoot.adoptedStyleSheets.includes(sheet)) {
      this.renderRoot.adoptedStyleSheets = [...this.renderRoot.adoptedStyleSheets, sheet]
    }
  }

  render() {
    const props = {color: this.color, size: this.size}
    return html`<span class=${classes(tag, props)} data-atlas=${atlasTag(tag, props)}><slot></slot></span>`
  }
}

// <atlas-text-field name="patient[name]" label="Name" value="…" error="…">
//
// A form-associated custom element (ElementInternals): the FORM sees it as one
// field named `name`, so LiveView's phx-change / phx-submit receive its value
// like any input's. It renders a native <input> (no name of its own) in light
// It renders into its own shadow root with the page's Atlas sheet adopted
// (rule 1), so LiveView never touches the input Lit renders and the element
// needs no phx-update="ignore". Its label, input, caption and error share
// that shadow root, so <label for> and aria-describedby resolve inside it.
// LiveView integration, learned in the POC:
//   * Everything the server owns after mount (value, error, label, caption)
//     arrives as data-* attributes (they were the only ones LiveView patched
//     under phx-update="ignore"; kept as the convention for all controls).
//   * LiveView reads the changed field from the input event's target. The
//     inner input has no name (it would double-submit), so its event is
//     re-dispatched from the host, which carries the form name.
class AtlasTextField extends LitElement {
  static formAssociated = true
  static properties = {
    name: {},
    required: {type: Boolean},
    label: {attribute: "data-label"},
    value: {attribute: "data-value"},
    error: {attribute: "data-error"},
    caption: {attribute: "data-caption"},
  }

  static shadowRootOptions = {...LitElement.shadowRootOptions, delegatesFocus: true}
  static styles = css`
    :host {
      display: block;
    }
  `

  constructor() {
    super()
    this.internals = this.attachInternals()
    this.value = ""
  }

  connectedCallback() {
    super.connectedCallback()
    const sheet = atlasSheet()
    if (sheet && !this.renderRoot.adoptedStyleSheets.includes(sheet)) {
      this.renderRoot.adoptedStyleSheets = [...this.renderRoot.adoptedStyleSheets, sheet]
    }
  }

  // The standard form-associated surface. LiveView finds the form to push
  // phx-change to through `el.form`, so without this getter it drops the
  // element's input events silently.
  get form() {
    return this.internals.form
  }
  get validity() {
    return this.internals.validity
  }
  get willValidate() {
    return this.internals.willValidate
  }

  willUpdate(changed) {
    if (changed.has("value")) this.internals.setFormValue(this.value ?? "")
  }

  formResetCallback() {
    this.value = ""
  }

  onInput(event) {
    event.stopPropagation()
    this.value = event.target.value
    this.internals.setFormValue(this.value)
    this.dispatchEvent(new Event("input", {bubbles: true}))
  }

  // Server-owned value changes (data-value) must not clobber what the user is
  // typing: only adopt the server's value while the input is not focused.
  shouldUpdate(changed) {
    if (changed.has("value") && this.matches(":focus-within")) {
      const typed = this.renderRoot.querySelector("input")?.value
      if (typed !== undefined && typed !== this.value) this.value = typed
    }
    return true
  }

  render() {
    const id = `${this.id || this.name}-input`
    const invalid = Boolean(this.error)
    const describedby = [this.caption && `${id}-caption`, invalid && `${id}-error`].filter(Boolean).join(" ")
    const part = (p) => classes(field, {part: p})

    return html`<div class=${part("root")} data-atlas="Field">
      <label for=${id} class=${part("label")}>${this.label}${this.required
        ? html`<span class=${part("required")} aria-hidden="true"> *</span>`
        : nothing}</label>
      <input
        id=${id}
        class=${classes(input, {state: invalid ? "invalid" : "default"})}
        data-atlas=${atlasTag(input, {state: invalid ? "invalid" : "default"})}
        .value=${this.value ?? ""}
        aria-required=${this.required ? "true" : nothing}
        aria-invalid=${invalid ? "true" : nothing}
        aria-describedby=${describedby || nothing}
        @input=${this.onInput}
      />
      ${this.caption ? html`<p id="${id}-caption" class=${part("caption")}>${this.caption}</p>` : nothing}
      ${invalid ? html`<p id="${id}-error" class=${part("error")}>${this.error}</p>` : nothing}
    </div>`
  }
}

export function defineAtlasElements() {
  if (!customElements.get("atlas-tag")) customElements.define("atlas-tag", AtlasTag)
  if (!customElements.get("atlas-text-field")) customElements.define("atlas-text-field", AtlasTextField)
  if (!customElements.get("atlas-multi-select")) customElements.define("atlas-multi-select", AtlasMultiSelect)
  if (!customElements.get("atlas-modal")) customElements.define("atlas-modal", AtlasModal)
  if (!customElements.get("atlas-drawer")) customElements.define("atlas-drawer", AtlasDrawer)
  // POC instrumentation: when the elements became usable, for the flash measure.
  window.__atlasDefinedAt = performance.now()
}
