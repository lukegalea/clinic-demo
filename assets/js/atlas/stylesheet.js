// Light-DOM Atlas elements style themselves with Tailwind utility classes, but
// an A2UI surface (`<a2ui-surface>`) renders its tree inside a shadow root,
// where the page's stylesheet does not apply. `adoptAtlasStyles(el)` copies
// the page's compiled app.css into ONE constructed stylesheet (built once,
// shared by reference) and adopts it into whatever shadow root the element
// lives in, once per root. Elements outside any shadow root need nothing.
// The compiled sheet is app.css in the app (a <link>) and storybook.css in the
// storybook (an @import inside phoenix_storybook's own sheet), so it is looked
// up by URL through @imports too.

let sheet = null

const COMPILED = /\/assets\/css\/(app|storybook)\.css(\?|$)/

function findCompiled(sheets) {
  for (const candidate of sheets) {
    if (COMPILED.test(candidate.href || "")) return candidate
    let rules
    try {
      rules = [...candidate.cssRules]
    } catch {
      continue // cross-origin (fonts): unreadable, and never ours
    }
    const imported = findCompiled(rules.filter((rule) => rule.styleSheet).map((rule) => rule.styleSheet))
    if (imported) return imported
  }
  return null
}

export function atlasSheet() {
  if (sheet) return sheet
  const compiled = findCompiled([...document.styleSheets])
  if (!compiled) return null
  sheet = new CSSStyleSheet()
  sheet.replaceSync([...compiled.cssRules].map((rule) => rule.cssText).join("\n"))
  return sheet
}

const adopted = new WeakSet()

export function adoptAtlasStyles(el) {
  const root = el.getRootNode()
  if (!(root instanceof ShadowRoot) || adopted.has(root)) return
  const s = atlasSheet()
  if (!s) return
  adopted.add(root)
  root.adoptedStyleSheets = [...root.adoptedStyleSheets, s]
}
