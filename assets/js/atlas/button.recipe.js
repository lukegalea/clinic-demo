import {recipe} from "./recipe.js"

// Atlas Button (Figma set 9f1ee7e6c33d8d6aabc26d62f5043f07f155065c).
// Axes and values follow Figma. Heights follow the Accessibility page's
// target-size table (sm 26, md 36, lg 48). The focus treatment is the one
// rule decided on 21 Sep 2026: border/focus, 2px, 1px offset.
// POC: class values are first-pass; the real ones come from the Figma specs.
export const button = recipe({
  name: "Button",
  figmaSet: "9f1ee7e6c33d8d6aabc26d62f5043f07f155065c",
  kind: "native",
  overflow: "grow",
  base: [
    "inline-flex items-center justify-center gap-2 whitespace-nowrap shrink-0",
    "font-sans font-medium rounded-(--atlas-radius-lg) border cursor-pointer",
    // The label is a child A2UI Text, which reads its colour and margin from
    // these private basic-catalog variables; point them at the button's own.
    "[--_a2ui-text-color:currentColor] [--_a2ui-text-margin:0]",
    "transition-colors motion-reduce:transition-none",
    "focus-visible:outline-(length:--atlas-focus-width) focus-visible:outline-offset-(length:--atlas-focus-offset)",
    "focus-visible:outline-(--atlas-border-focus) focus-visible:outline-solid",
    "disabled:cursor-not-allowed disabled:bg-(--atlas-bg-disabled) disabled:text-(--atlas-text-disabled) disabled:border-transparent",
  ].join(" "),
  variants: {
    variant: {
      primary: "bg-(--atlas-bg-brand) text-(--atlas-text-on-brand) border-transparent hover:bg-(--atlas-bg-brand-hover)",
      secondary: "bg-(--atlas-bg-surface) text-(--atlas-text-primary) border-(--atlas-border-strong) hover:bg-(--atlas-bg-neutral-subtle)",
      ghost: "bg-transparent text-(--atlas-text-brand) border-transparent hover:bg-(--atlas-bg-brand-subtle)",
      destructivePrimary: "bg-(--atlas-bg-danger) text-(--atlas-text-on-danger) border-transparent hover:bg-(--atlas-bg-danger-hover)",
      link: "bg-transparent text-(--atlas-text-brand) border-transparent underline-offset-2 hover:underline hover:text-(--atlas-text-brand-hover) px-0!",
    },
    size: {
      sm: "h-[26px] px-3 text-xs",
      md: "h-9 px-4 text-sm",
      lg: "h-12 px-6 text-base",
    },
  },
  defaults: {variant: "secondary", size: "md"},
})
