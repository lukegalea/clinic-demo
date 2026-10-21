// Writes every Atlas recipe to priv/atlas/recipes.json, the input of the
// generated HEEx twins (Atlas.Components). Run through `mix atlas.recipes`.
//
//   node assets/js/atlas/export-recipes.mjs [--check]

import {readFileSync, writeFileSync} from "node:fs"
import * as recipes from "./recipes.js"

const out = new URL("../../../priv/atlas/recipes.json", import.meta.url)
const json =
  JSON.stringify(
    Object.fromEntries(Object.values(recipes).map((r) => [r.name, r])),
    null,
    2,
  ) + "\n"

if (process.argv.includes("--check")) {
  let current = ""
  try {
    current = readFileSync(out, "utf8")
  } catch {}
  if (current !== json) {
    console.error("priv/atlas/recipes.json is stale: run `mix atlas.recipes`")
    process.exit(1)
  }
  console.log("priv/atlas/recipes.json is up to date")
} else {
  writeFileSync(out, json)
  console.log("wrote priv/atlas/recipes.json")
}
