import {recipe} from "./recipe.js"

// Atlas Input (Figma set 9bb504cb1a30b6aa10deec8d071f26e301b2f4a7), and the
// Field around it (label, caption, error). Native kind: a real <input> with
// Atlas classes, in HEEx and in Lit alike.
// Height 34px (Accessibility page, input family). Overflow "truncate"
// (Bilingual page): single line, ellipsis, never grows.
// The focus rule is the one decided on 21 Sep 2026; invalid pairs the red
// border with a message (never colour alone).
// POC: class values are first-pass; the real ones come from the Figma specs.
export const input = recipe({
  name: "Input",
  figmaSet: "9bb504cb1a30b6aa10deec8d071f26e301b2f4a7",
  kind: "native",
  overflow: "truncate",
  base: [
    "block w-full min-w-0 h-[34px] px-3 text-sm font-sans text-ellipsis",
    "bg-(--atlas-bg-surface) text-(--atlas-text-primary) placeholder:text-(--atlas-text-placeholder)",
    "border rounded-(--atlas-radius-lg)",
    "focus-visible:outline-(length:--atlas-focus-width) focus-visible:outline-offset-(length:--atlas-focus-offset)",
    "focus-visible:outline-(--atlas-border-focus) focus-visible:outline-solid",
    "disabled:bg-(--atlas-bg-disabled) disabled:text-(--atlas-text-disabled) disabled:cursor-not-allowed",
  ].join(" "),
  variants: {
    state: {
      default: "border-(--atlas-border-strong)",
      invalid: "border-(--atlas-border-danger)",
    },
  },
  defaults: {state: "default"},
})

// The Field's parts. Not variant tables, just the shared classes, so the
// HEEx Field and <atlas-text-field> lay out a label, caption and error the
// same way.
export const field = recipe({
  name: "Field",
  figmaSet: "4d90d30eae1c60af2204d69aeb05af2290244d23",
  kind: "native",
  overflow: "wrap",
  // A multi-part component: `base` applies to every part, so it holds only
  // what every part shares; layout belongs to the root part.
  base: "font-sans",
  variants: {
    part: {
      root: "flex flex-col gap-1 min-w-0",
      label: "text-sm font-medium text-(--atlas-text-primary)",
      required: "text-(--atlas-text-danger)",
      caption: "text-xs text-(--atlas-text-tertiary)",
      error: "text-xs text-(--atlas-text-danger)",
    },
  },
  defaults: {part: "root"},
})
