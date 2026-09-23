# Visual/behavioral regression suite

A self-contained Node suite that gates the app's user-visible surface the way
the Elixir-only CI could not: three separate incidents (wiped static assets,
dead Tailwind classes, an unconsumed framework skin) all shipped green past
`mix test`. This suite asserts what a browser actually renders.

## Run it

The app must be up (defaults to `http://127.0.0.1:4000`):

```sh
bin/dev                      # or mix phx.server, whatever serves the app
cd test/visual
npm ci                       # first time only
npx playwright install --with-deps chromium   # first time only
node run.mjs --base-url http://127.0.0.1:4000
```

Flags:

| flag | meaning |
| --- | --- |
| `--base-url <url>` | where the app lives (default `http://127.0.0.1:4000`; `BASE_URL` env also works) |
| `--update-baselines` | rewrite the committed baselines with what the app renders now — for deliberate visual changes only, and say so in the commit message |
| `--grep <pattern>` | run only checks whose id contains the pattern (`page:patients`, `behavior:view-opens-readonly`, …) |

Exit code is the gate: `0` green, `1` any failure, `2` a grep that matched
nothing. Never pipe it through `tail`/`grep` without `set -o pipefail`.

Use `http://localhost:4000` rather than `http://127.0.0.1:4000` when the app
boots under `MIX_ENV=test`: the endpoint's url host is the default
`localhost`, and `check_origin` rejects the LiveView websocket for any other
host — the a2ui surfaces and the `/acting-as` roster stay dead over
`127.0.0.1`. (The dev server sets `check_origin: false`, so either works
there.)

## Vendor fallback (no npm registry / no browser download)

If the machine has a Playwright checkout and a system Chrome already, the
suite can run against those instead:

```sh
PLAYWRIGHT_NODE_MODULES=/path/to/node_modules \
CHROME=/usr/bin/google-chrome \
node run.mjs --base-url http://127.0.0.1:4000
```

Caveat: the committed baselines are canonical for the bundled Chromium that
`playwright@1.57.0` drives at a 1280x800 light-scheme viewport. A system
Chrome antialiases text slightly differently; expect screenshot noise and
reach for `--update-baselines` only after eyeballing the actual change.

## What is checked

Per surface (15 pages: `/`, `/intake`, `/schedule`, `/worklist`, `/visits`,
`/patients`, `/clinicians`, `/processes`, `/decisions`, `/evaluations`,
`/events`, `/operator`, `/operator/rules`, `/canvas`, `/agent`):

- HTTP 200, and `/assets/js/app.js` served — the wiped-asset guard.
- Zero console errors / page errors.
- The app chrome: nav row, `main` region, acting-as pill; plus a
  per-surface marker (hydrated `a2ui-surface`, page heading, framework host
  or literal text) and the nav pill's `aria-current` claim on the route.
- **Dead-CSS detector**: every visible, labeled button in the app chrome and
  framework chrome (shadow DOM pierced one level for a2ui hosts) must
  compute real styling — non-zero border, a box shadow or a background. A
  bare (preflight-only) or browser-default (outset border) button is the
  dead-Tailwind incident wearing a different hat. Icon-only buttons are
  skipped (the theme toggle's segments are deliberately flat inside their
  chrome-bearing container).
- Full-page screenshot against `__screenshots__/<page>.png`. Before capture,
  seeded volatility (times, dates, ids, counts) is digit-scrubbed to "8"s and
  presence chips are hidden, so baselines move only when structure moves.

Behavioral pins (from the view/edit/save interaction audit):

- View on `/patients` opens a READ-ONLY panel (no editable controls added;
  the old "view-opens-edit" bug).
- The formless surfaces (`/visits`, `/processes`, `/decisions`) render no
  View row control at all.
- A row-action success renders visible feedback (the old invisible
  `/ui/status` write).
- An anonymous write on `/patients` is refused with a visible message.
- `/events` renders the seeded event stream — the lifecycle's bookings,
  check-ins, completions and the discharge, plus DMN triage evaluations,
  each as its `action on Resource` row in the ash_events feed. (The old
  empty-state pin died with the empty state: the log is written by
  ash_events now, and the suite runs against a seeded database, so a
  zero-row log is not honestly drivable here.)
- A stale `/acting-as` roster pick redirects to the picker with an error
  flash — no raw `422 "unknown actor"` page.
- The intake patient picker composite upgrades, searches and surfaces real
  options — asserted with the create panel OPEN (the composite only exists
  once the form does).
- The process designer renders the catalogue datalist
  (`#config-action-options`) when a service task is selected.
- The actor pill shows WHO is acting; presence chips appear on the nav for
  other sessions.

## Known gaps

None. The suite has no expected-fails — every red line is a real regression.
The one console error the intake combobox once logged (`no DOM ID for hook
"AshA2uiCombobox"`) was fixed host-side: the hook element in
`ClinicDemoWeb.A2ui.IntakeLive` now carries a DOM id
(`intake_patient_id_combobox`), which LiveView hooks require.

## CI

`.github/workflows/elixir.yml` runs this suite as a required `visual` job:
postgres service → `mix ash.setup` + `mix seed` → `mix assets.setup` +
`mix assets.build` → `npm ci` + `npx playwright install --with-deps
chromium` → `mix phx.server` (MIX_ENV=test, PHX_SERVER=true, PORT=4000) →
`node run.mjs`. Failures upload the actual/diff PNGs as artifacts.
