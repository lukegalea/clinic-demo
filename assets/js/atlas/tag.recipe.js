import {recipe} from "./recipe.js"

// Atlas Tag (Figma set 258f0aad9135287e08bf17401fb546f06914345b).
// Static: no behaviour, so the HEEx twin is generated from this same recipe.
// Overflow "grow" (Bilingual page): a tag never clips; the layout absorbs it.
// Heights follow the Accessibility page (Tag sm is 24px, on the 24px line).
// POC: fills use the semantic subtle/strong token pairs; Figma's own tag/*
// pair tokens replace them once they are pulled from the library.
export const tag = recipe({
  name: "Tag",
  figmaSet: "258f0aad9135287e08bf17401fb546f06914345b",
  kind: "static",
  overflow: "grow",
  base: "inline-flex items-center gap-1 shrink-0 whitespace-nowrap rounded-(--atlas-radius-full) font-sans font-medium leading-none",
  variants: {
    color: {
      blue: "bg-(--atlas-bg-info-subtle) text-(--atlas-text-brand)",
      gold: "bg-(--atlas-bg-pending-subtle) text-(--atlas-text-pending)",
      green: "bg-(--atlas-bg-success-subtle) text-(--atlas-text-success)",
      orange: "bg-(--atlas-bg-warning-subtle) text-(--atlas-text-warning)",
      red: "bg-(--atlas-bg-danger-subtle) text-(--atlas-text-danger)",
      neutral: "bg-(--atlas-bg-neutral) text-(--atlas-text-secondary)",
    },
    size: {
      sm: "h-6 px-2 text-xs",
      md: "h-7 px-2.5 text-xs",
      lg: "h-8 px-3 text-sm",
    },
  },
  defaults: {color: "neutral", size: "md"},
})
