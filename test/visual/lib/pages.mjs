// The page inventory: the fifteen standing surfaces of the app, each with
// the marker that says "this is the surface I claim to be".
//
// Marker kinds:
//   { kind: "a2ui" }            — an <a2ui-surface> host with a hydrated shadow root
//   { kind: "h1", text }        — a controller/live page heading
//   { kind: "host", selector }  — a framework host element or DOM id
//   { kind: "text", text }      — literal (shadow-piercing) text content
//
// `navCurrent` is set for surfaces that own a nav pill: the pill with
// aria-current="page" must point at this route. /events deliberately has no
// nav pill (the nav's a2ui entries stop at Evidence), and the operator
// sub-pages, /canvas and /agent are reachable from the operator hub.

export const PAGES = [
  { route: "/", name: "board", marker: { kind: "a2ui" }, navCurrent: "/" },
  { route: "/intake", name: "intake", marker: { kind: "a2ui" }, navCurrent: "/intake" },
  { route: "/schedule", name: "schedule", marker: { kind: "a2ui" }, navCurrent: "/schedule" },
  {
    route: "/day",
    name: "day",
    marker: { kind: "h1", text: "Day" },
    extraMarker: { kind: "host", selector: "#day-calendar" },
    navCurrent: "/day",
  },
  { route: "/worklist", name: "worklist", marker: { kind: "a2ui" }, navCurrent: "/worklist" },
  { route: "/visits", name: "visits", marker: { kind: "a2ui" }, navCurrent: "/visits" },
  { route: "/patients", name: "patients", marker: { kind: "a2ui" }, navCurrent: "/patients" },
  { route: "/clinicians", name: "clinicians", marker: { kind: "a2ui" }, navCurrent: "/clinicians" },
  { route: "/processes", name: "processes", marker: { kind: "a2ui" }, navCurrent: "/processes" },
  { route: "/decisions", name: "decisions", marker: { kind: "a2ui" }, navCurrent: "/decisions" },
  { route: "/evaluations", name: "evaluations", marker: { kind: "a2ui" }, navCurrent: "/evaluations" },
  {
    route: "/events",
    name: "events",
    marker: { kind: "a2ui" },
    // The feed's time-column label — the surface never renders its own
    // title into the shadow DOM, so this (plus the screenshot baseline and
    // the stream-renders behavioral pin) is the hydration proof.
    extraMarker: { kind: "text", text: "When" },
  },
  { route: "/operator", name: "operator-hub", marker: { kind: "h1", text: "Operator" }, navCurrent: "/operator" },
  {
    // The static capstone slideshow (CLIN-6): a standalone page — no app
    // chrome, no nav pill (that is the deck's whole point), so `noChrome`
    // skips the chrome check. The arrow-key pin below proves it navigates.
    route: "/deck",
    name: "deck",
    marker: { kind: "h1", text: "The Vet Clinic Capstone" },
    noChrome: true,
  },
  {
    route: "/operator/rules",
    name: "operator-rules",
    marker: { kind: "h1", text: "Rule sets" },
    extraMarker: { kind: "host", selector: "style#ruleset-editor-skin", hidden_ok: true },
  },
  {
    route: "/operator/surfaces",
    name: "operator-surface-editor",
    marker: { kind: "h1", text: "Surface editor" },
    extraMarker: { kind: "text", text: "Import" },
  },
  {
    route: "/canvas",
    name: "canvas",
    marker: { kind: "h1", text: "Canvas" },
    extraMarker: { kind: "host", selector: "ash-canvas-graph" },
  },
  {
    route: "/agent",
    name: "agent",
    marker: { kind: "h1", text: "Helper" },
    extraMarker: { kind: "host", selector: "#agent-request" },
  },
];

// The a2ui surfaces whose row-action machinery the behavioral pins exercise.
export const FORMLESS_SURFACES = ["/visits", "/processes", "/decisions"];

export function markerSelector(marker) {
  switch (marker.kind) {
    case "a2ui":
      return "a2ui-surface";
    case "h1":
      return `h1:text-is(${JSON.stringify(marker.text)})`;
    case "host":
      return marker.selector;
    case "text":
      return `text=${JSON.stringify(marker.text)}`;
    default:
      throw new Error(`unknown marker kind: ${marker.kind}`);
  }
}
