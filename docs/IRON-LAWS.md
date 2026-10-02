# The iron-laws gate

The 26 Iron Laws (the `ash_agent_tools:iron-laws` section of `AGENTS.md`) are
judged deterministically with `mix ash_agent.laws`, gated in `mix precommit`
and CI at the judge's default floor, `likely`. The gate is
`scripts/iron-laws.sh`; the reviewed exceptions live in
`scripts/iron-laws.baseline.json`. The standing dispositions — law 21 on
`core_components.ex` and law 16 on `ClinicDemo.Rules.read!/1` — are stated in
`usage-rules.md` and are not re-litigated here.

`scripts/iron-laws.sh` runs the judge two ways:

- **diff**: every line added since the merge base with `origin/main`,
  including uncommitted and untracked files. In CI, the base is the PR's
  target branch, or for a push, the commit the push started from. An empty
  diff passes.
- **tree**: every tracked `.ex`, `.exs` and `.heex` file, checked against
  `scripts/iron-laws.baseline.json`. This mode catches what the diff mode
  can't see: the judge skips its whole-file detectors on a diff, because a
  diff lacks the context they need.

Both modes fail on any hit at `likely` or above that isn't in the baseline.
Review-tier hits are counted but never fail the run. The tree mode also fails
when a baseline entry stops firing, so an excuse can't outlive the code it
excused. The judge is pure text processing — it neither boots nor compiles
the application — but it needs the `ash_agent_tools` Mix task on the path, so
it always runs under `MIX_ENV=dev` (the dep is `only: :dev`), including from
`mix precommit`, which itself runs under `test`.

## The baseline, as landed (2026-10-02, ash_agent_tools 0b7d9bc)

The full tree was judged at the `review` floor before the gate was switched
on. **12 hits at `likely` or above**, every one accounted for below; **8
review-tier notes, never failing**.

| Law | Hits | Tier | Why it stays |
|---|---|---|---|
| #21 no `assign_new` for per-mount values | 5 | likely | Standing disposition: function components in the generated `core_components.ex`, where `assign_new` defaults an attribute the caller left out. The law is about LiveView `mount`. |
| #11 authorize every `handle_event` | 3 | likely | Each reviewed: `agent_live` and `canvas_live` pass the signed-in viewer as actor to their Ash-backed reads; `day_live`'s handler calls no Ash action at all (it filters assigns loaded at mount). |
| #10 no `String.to_atom` on user input | 3 | definite | Compile-time constants: storybook variation ids from `~w()` sigils of developer-authored names, the exception the law itself makes. |

Review-tier notes (8, never failing): #16 `File.read!` without
`@external_resource` (6) — the standing disposition on
`ClinicDemo.Rules.read!/1` plus fixtures and spike runners read at runtime,
not compile time; #02, two comprehensions over assigns in a component and a
rendered page.

## Adding to the baseline

Fix the code if you honestly can — and note that a lockfile bump of
`ash_agent_tools` can change what fires (detector fixes clear hits, new
detectors raise them); the tree mode surfaces both. If a hit really is a
false positive, add `{law, file, text, reason}` to the baseline in the same
commit. `text` is the flagged line with its leading and trailing whitespace
trimmed, and `reason` must be something a reviewer can check. Keys never
include line numbers, so an edit elsewhere in the file doesn't invalidate an
entry. A hit not covered by an existing disposition gets fixed or gets a line
here and in `usage-rules.md`.
