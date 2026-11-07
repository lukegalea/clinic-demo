// The mermaid engine's own bundle entry: the esbuild args list names this
// file, and it re-exports ash_a2ui's engine (the one place `mermaid` is
// imported), publishing itself on window.AshA2uiMermaid for the IIFE route
// (see deps/ash_a2ui/priv/js/ash_a2ui_mermaid.js, wiring option 2).
import "../../deps/ash_a2ui/priv/js/ash_a2ui_mermaid.js";
