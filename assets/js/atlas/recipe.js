// Atlas recipes: a component's variant table as data.
//
// A recipe names its Figma component set, its kind (interactive | static |
// native) and, per Figma variant axis, the Tailwind classes each value adds.
// Classes reference Atlas tokens only, through `--atlas-*` custom properties
// (e.g. `bg-(--atlas-bg-brand)`), so a recipe can never name a colour that is
// not in priv/atlas/tokens.json.
//
// `classes(recipe, props)` resolves a recipe for one set of props; `tag(recipe,
// props)` is the `data-atlas` value ("Button/primary/md") that conformance
// checks and visual tests read.

export function recipe(spec) {
  for (const [axis, def] of Object.entries(spec.defaults || {})) {
    if (spec.variants?.[axis]?.[def] === undefined) {
      throw new Error(`Atlas recipe ${spec.name}: default ${axis}=${def} is not a declared value`)
    }
  }
  return Object.freeze(spec)
}

export function resolve(recipe, props = {}) {
  const out = {}
  for (const axis of Object.keys(recipe.variants || {})) {
    const value = props[axis] ?? recipe.defaults?.[axis]
    out[axis] = recipe.variants[axis][value] !== undefined ? value : recipe.defaults?.[axis]
  }
  return out
}

export function classes(recipe, props = {}) {
  const chosen = resolve(recipe, props)
  const parts = [recipe.base]
  for (const [axis, value] of Object.entries(chosen)) parts.push(recipe.variants[axis][value])
  return parts.filter(Boolean).join(" ")
}

export function tag(recipe, props = {}) {
  return [recipe.name, ...Object.values(resolve(recipe, props))].join("/")
}
