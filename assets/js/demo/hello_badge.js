// Demo: the smallest useful Lit component, for explaining Lit to the team
// (shown on /atlas-lab). A class that IS the <hello-badge> element: reactive
// properties, a template, scoped styles, an event listener. Atlas tokens reach
// inside its shadow root because they are CSS custom properties.

import {LitElement, html, css} from "lit"

class HelloBadge extends LitElement {
  // Change any of these and Lit re-renders only what changed.
  static properties = {name: {}, count: {type: Number}}

  // Scoped to this element's shadow root: they can't leak out, page CSS can't leak in.
  static styles = css`
    :host {
      display: inline-flex;
      align-items: center;
      gap: var(--atlas-spacing-8);
      font-family: var(--atlas-font-family-sans);
    }
    span {
      background: var(--atlas-bg-info-subtle);
      color: var(--atlas-text-brand);
      padding: 2px 8px;
      border-radius: var(--atlas-radius-full);
    }
    button {
      font: inherit;
      padding: 2px 8px;
      border: 1px solid var(--atlas-border-strong);
      border-radius: var(--atlas-radius-lg);
      background: var(--atlas-bg-surface);
      cursor: pointer;
    }
    button:focus-visible {
      outline: var(--atlas-focus-width) solid var(--atlas-border-focus);
      outline-offset: var(--atlas-focus-offset);
    }
  `

  constructor() {
    super()
    this.name = "team"
    this.count = 0
  }

  render() {
    return html`
      <span>Hello, ${this.name}</span>
      <button @click=${() => this.count++}>Clicked ${this.count}</button>
    `
  }
}

if (!customElements.get("hello-badge")) customElements.define("hello-badge", HelloBadge)
