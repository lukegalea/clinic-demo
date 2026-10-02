# System One spike-0: `ash_ai` evaluate against Ollaya

**Status (2026-09-28): wire-level only. No model has answered yet.**

The harness is built and tested end to end over the TypeSafe wire, with
labelled record/replay fixtures. It has **not** been run against a live Ollaya,
because the dev-zone endpoints file (`~/.config/system-one/endpoints.env`) did
not exist when this ran. So:

- there are no model numbers here, and no go/no-go;
- the stub results under `priv/fixtures/system_one/spike0/results/stub/`
  measure the harness, not a model. Their first line says so, and the runner
  refuses to give them a verdict;
- the findings in [What the wire-level run established](#what-the-wire-level-run-established)
  are real. They are about ReqLLM, `ash_ai` and `ash_decisions`, and do not
  depend on a model.

The live run is one command once the endpoints file exists:
[Live run](#live-run). Its output drops into [Live results](#live-results-template).

Ticket: Plane S1-21 (F-SPIKE0). Branch: `spike/system-one-0`.

## Scope as run

The ticket was re-scoped twice on 2026-09-28. This spike follows the latest:

- **In:** Ollaya-served decision models only: `laya:typed-decisions` and
  `winnow:e4b`.
- **Removed:** hosted Jev, `TYPESAFE_API_KEY` and AC-2 (DEC-HOSTED "never").
  `decider:2b`, because it does not fit the GPU. The code names no hosted model
  and no `-latest` alias; a test greps for one.
- **Elsewhere:** the schema-constrained generative leg (Qwen on the M5 Pro) is
  CLIN-34's extract-then-verify spike, not this one. NLI and GLiClass baselines
  were optional and are not included.
- **Hardware:** V1 is now three dev-zone boxes. This spike needs only the Ollaya
  box (the laptop).

## What was built

| Piece | Where |
|---|---|
| Spike resource, three `run evaluate(...)` actions | `lib/clinic_demo/system_one_spike.ex`, domain `ClinicDemo.Spikes` |
| Model resolver (tuple specs, `base_url` per call) | `lib/clinic_demo/system_one_spike/models.ex` |
| Record/replay/stub transport, at the HTTP layer | `lib/clinic_demo/system_one_spike/transport.ex`, `stub.ex` |
| Runner, metrics, report | `runner.ex`, `metrics.ex`, `report.ex`, `mix clinic.spike0` |
| Spike-only band table | `priv/decisions/spike/urgency_suggestion_band.dmn`, `band.ex` |
| Labelled items (53) and their generator | `priv/fixtures/system_one/spike0/items.jsonl`, `build_items.exs` |
| Committed stub replay set | `priv/fixtures/system_one/spike0/replay/stub.jsonl` |
| Live-run script | `scripts/spike0-live.sh` |
| Tests (42, no network) | `test/clinic_demo/system_one_spike/` |

The three actions:

- `notes_follow_up` returns `AshAi.Evaluate.Noul` over `notes`, with the
  ticket's instructions and true/false criteria.
- `presenting_urgency` returns `AshAi.Evaluate.Choice` over `reason`, `species`
  and `age_band`. Its options are read at compile time from
  `Appointment.triage_urgency`'s `one_of`, plus `:insufficient_information`.
- `both` returns `AshAi.Evaluate.Judgments` with both questions, in one request.

Each returns `AshAi.Actions.Result`, so every answer arrives with the model id
the server reported and its token usage. Nothing writes: no data layer, no
ledger, and no change to `AppointmentFacts`, the guard, or
`appointment_triage.dmn`.

### How requests leave the process

The action resolves a tuple model spec from its input context:

```elixir
{:typesafe, "laya:typed-decisions", base_url: ollaya_base_url, api_key: key, receive_timeout: 60_000}
```

ReqLLM's own TypeSafe provider builds and decodes every request, in every mode.
For record, replay and stub, the spec also carries
`req_http_options: [plug: {Transport, ...}]`. Req then runs the plug in place of
the network, so only the bytes on the wire are substituted:

- **record**: the plug forwards the body unchanged to Ollaya and writes both
  sides to a fixture set, provenance `recorded`;
- **replay**: it answers from the set, keyed by a hash of the request body plus
  a repeat tag (`r1`–`r3`, `cold`), so run-to-run variance replays too. A miss
  is an error, never a live call;
- **stub**: it answers from a naive keyword stub, provenance `stub`.

Fixtures never hold request headers or the upstream URL. A test checks this.

### Why not ReqLLM's `fixture:` option

The ticket suggested ReqLLM's `fixture:` option. Its backend,
`ReqLLM.Step.Fixture.Backend`, exists only in req_llm's own test environment,
so in an application the option silently does nothing. Req's plug adapter
exercises more of the real path anyway.

## Items and labelling protocol

53 synthetic items, CC0 (REUSE annotation for `priv/fixtures/system_one/**`).
Patient names are obviously fictional pet names.

| Question | Stratum | N |
|---|---|---|
| `notes_follow_up` | clear positive | 6 |
| | clear negative | 6 |
| | hard negative: negation, another animal's plan, cancelled plan, conditional plan, copy-pasted template line, declined, vague monitoring | 7 |
| | length probe: ≈300 / 900 / 1,100 / 1,600 tokens, one positive and one negative at each | 8 |
| `presenting_urgency` | clear, 4 per option | 16 |
| | hard: alarming words for a resolved problem, owner distress, no-keyword emergencies, urgency carried by age band, a routine request hiding a chronic sign | 6 |
| | abstain (gold `insufficient_information`) | 4 |

In every length probe, the deciding sentence comes **last**. If a server
silently truncates from the end, the answer flips, instead of the truncation
going unnoticed.

Token counts are approximate: JSON state bytes divided by 4. laya's tokenizer
is not available here. The ≈1,100 probes sit about 7% past 1,024 by this
estimate. If laya's real count comes in under the limit, the 1,600 probes
still cross it.

**Labels are the author's only.** Each item carries `labeller: "author"` and
`second_label: null`. The blind second labelling (Luke, or a named second
labeller) has not happened. No items have been dropped yet. When it happens,
drop the items where the two labels disagree, record how many were dropped
here, and re-run the replay.

## What the wire-level run established

These are true now, with no model involved. Each has a test.

1. **The call path works as designed.** A tuple spec with `base_url` reaches
   `POST /v1/systemone`. The request carries `authorization: Bearer <key>`, the
   model id, the action's arguments as the state, and each question typed
   (`noul` with `true`/`false` criteria, `choice` with one criterion per
   option). A TypeSafe-shaped reply casts cleanly into `Noul`, `Choice` and
   `Judgments`. `Result.model` is whatever the reply's `model` field says. ReqLLM
   requires that field, so whether Ollaya puts a version or digest there is
   answered by the first live reply.

2. **A reply without `usage` fails everything.** ReqLLM's TypeSafe decoder
   rejects a 200 reply unless it has `model`, `answers` and `usage`. The error is
   "Invalid TypeSafe evaluation response", and nothing casts. Ollaya claims
   API-level compatibility, not parity, so if it omits `usage`, every call
   fails. This is the first thing the live smoke test shows.

3. **A context overflow is a structured error, not a crash (AC-5, client
   side).** A 422 arrives as `{:error, %Ash.Error.Unknown{}}` wrapping
   `ReqLLM.Error.API.Request`, with `status: 422` and the server's body intact.
   ReqLLM does not retry 4xx replies, and neither layer truncates the state.
   Whether *Ollaya* truncates silently is the live question the probes answer.
   The stub's 422 body (`{"error": {"code": "STATE_TRUNCATED"}}`) is **assumed**;
   Ollaya documents the code but not the body.

4. **ReqLLM's error carries the whole request body, state included.** Any log
   line that inspects the error writes the state to the log. That is harmless
   here, where the data is synthetic. It matters for VPM-33, where the state
   will be real certificate text inside the zone: log a projection of the error
   (like `Runner.describe_error/1`, which keeps the status and the server's
   reply and drops the request), never `inspect(error)`.

5. **The `ash_decisions` verifier cannot decide ranges when a numeric column
   declares `inputValues`.** With `<inputValues>[0..1]</inputValues>` on a
   number column, the verifier treats `[0..1]` as a single enum value, and every
   range cell becomes an `:opaque_entry` obligation. So nothing is proved. The
   band table therefore declares no numeric `inputValues`, and uses open
   comparisons (`>= 0.8` / `< 0.8`) that cover every number. With that change it
   verifies with **no findings and no obligations** (AC-7). A test also shows
   the verifier catches an overlap when one is planted. The `inputValues`
   behaviour is worth raising against `ash_decisions`: a declared numeric domain
   should bound the regions, not replace them.

Two more checks were run by hand and are not in the suite:

- `scripts/spike0-live.sh` was run end to end against a throwaway local HTTP
  server that speaks the wire shape. Record, forward, replay and the
  smoke-latency check all worked, and the replayed summary matched the recorded
  one exactly, recorded latencies included. The fake server's fixtures were
  deleted, not committed.
- Replaying the committed stub set reproduces the stub summary exactly.

## Harness check (stub, not a model)

`mix clinic.spike0` replays the committed stub set and prints the full report.
It exercises every metric and every code path, including the 422 on the laya
length probes (the stub enforces 1,024 tokens for laya and an assumed 8,192 for
winnow). The numbers are in `results/stub/summary.md`. **They are not model
results.** Latency is zero by construction, and the stub's naive keyword rules
fail every hard choice item.

## Host routing (2026-10-02)

The dev zone now has two Ollaya hosts, and the spike routes per model:
`S1_OLLAYA_ROUTES` in the endpoints file maps each model id to `CPU` or `GPU`;
`CPU` reads `OLLAYA_BASE_URL`, `GPU` reads `S1_OLLAYA_GPU_BASE_URL`. With the
routes variable unset, every model still uses `OLLAYA_BASE_URL`, so replay,
stub and CI behave exactly as before. `Models.ollaya_base_url/1` fails loud
when the routes are set but name no host for a model, or the named host is not
set — a result file must never lie about which host answered — and the live
script's smoke test, HTTP provenance capture and unload command all resolve
the same routes.

Standing rules for any future image work (recorded here, not implemented):

- Images go to `decider:2b-vision` (`S1_OLLAYA_VISION_MODEL`) on the GPU host,
  as **region crops of ≤ 0.5 MP** (`S1_OLLAYA_VISION_MAX_PIXELS`). A crop is
  more decisive than a shrunken page, and ≥ 0.8 MP OOMs the 2080 Ti.
- Image embeddings only via llama.cpp `multimodal_data`, with the server's
  `media_marker` from `GET /props` (`S1_EMBED_IMAGE_MODE`). The legacy
  `image_data` form silently ignores the image.

## Live run

When `~/.config/system-one/endpoints.env` exists:

```bash
cd ~/ast-forks/clinic-demo            # or a worktree of spike/system-one-0
OLLAYA_SSH=luke@<laptop> scripts/spike0-live.sh
# toolchain from ash_enterprise's devenv, if mix is not on PATH:
#   MIX="<wrapper that runs devenv shell -- mix in this directory>" scripts/spike0-live.sh
```

The endpoints file needs `OLLAYA_BASE_URL` (for example
`http://<laptop>:11435`, with or without `/v1`) and, if the server wants one,
`OLLAYA_API_KEY`. When the run's models live on two hosts, it also needs
`S1_OLLAYA_GPU_BASE_URL` and the `S1_OLLAYA_ROUTES` map. The script also
accepts `OLLAYA_URL`. It never prints any of these values.

What the script does:

1. Captures each host's Ollaya version over HTTP (`/api/version`, degrading to
   "not reported") and every run model's digest and `size_vram` from
   `/api/tags` and `/api/ps`, into `results/live-<date>/environment.txt`.
   With `OLLAYA_SSH` set it also records `ollaya show` output over ssh. URLs
   and keys are never written.
2. **GPU smoke test.** It sends one load request per model — to the host its
   route names — then five warm one-question requests. If the warm median is
   over `S1_GPU_MAX_MS` (default 400 ms), it suspects a silent CPU fallback
   and stops before recording. It saves `ollaya ps` for the record when
   `OLLAYA_SSH` is set. `FORCE=1` records anyway.
3. Records every item, 3 repeats, with one cold request per model first. The
   unload command is `ssh $OLLAYA_SSH ollaya stop {model}`, or, without ssh,
   a curl `keep_alive: 0` POST to `/api/generate` on the model's own host.
   A failed unload is a warning, never fatal.
4. Replays the recording with no network, into `results/live-<date>-replay/`.
   The two summaries must match.

Then commit `replay/live-<date>.jsonl`, `results/live-<date>/`, and this
document with the template below filled in. Keep the stub set; CI replays it.

To preload on the laptop: `laya:typed-decisions` and `winnow:e4b`, with the
Ollaya version pinned. The smoke test's load request absorbs a cold load either
way.

## Live results (template)

Fill this section from `results/live-<date>/summary.md` and `environment.txt`.
Until then, every field reads *not run*.

**Setup.** Ollaya version: *not run*. Digests: `laya:typed-decisions` *not run*,
`winnow:e4b` *not run*. Host and GPU: *not run*. GPU smoke, warm median:
laya *not run* ms, winnow *not run* ms. `ollaya ps` shows GPU: *not run*.

**Wire compatibility.**

| Check | laya | winnow |
|---|---|---|
| `Result.model` populated? Version or digest in it? | not run | not run |
| `usage` present? | not run | not run |
| Noul / Choice / Judgments cast without error? | not run | not run |
| Overflow reply at ≈1,100 / 1,600 tokens: 422 `STATE_TRUNCATED`, other error, or silent truncation (answer flips on the probe pair)? | not run | not run |

**Metrics.** Paste the Noul, Choice, and latency/batching/variance tables from
`summary.md`. Keep its provenance line. N is in every row.

**Reliability.** Paste the `reliability` arrays from `summary.json` as a
10-row table per spec (bin, n, mean p, observed rate), noting that most bins
hold one or two items at this N.

**Recommendation.** *Not run.* Answer three questions:
- Which local model is the default?
- Does laya's 1,024-token limit force atom-sized state? This feeds the
  compliance track's atomiser.
- Does batching (`both`) change answers, or only latency?

## Go / no-go (AC-4)

The decision rule, fixed before any model ran:

> **Go** for building the substrate only if at least one local spec reaches,
> on the noul: AUROC ≥ 0.85, selective accuracy ≥ 0.95 at a coverage of at
> least 40% for some threshold, and warm p95 latency ≤ 250 ms. Otherwise
> **no-go** or **go-with-conditions**, with reasons. The same numbers are
> reported for the choice.

The ticket's 250 ms bar was written for a CPU host. The spike now runs on a GPU
box, so the bar stands as written.

**Outcome: not evaluated.** No live results exist. The runner computes the rule
automatically, but only when every result's provenance is `live` or
`recorded`.

## Acceptance status

| AC | Status |
|---|---|
| AC-1 Ollaya noul, `Result.model` recorded | Wire-level only. The path is proved with a TypeSafe-shaped reply; the live reply is pending. |
| AC-2 hosted Jev | Removed from scope (DEC-HOSTED "never"). A static grep test guards against `-latest`. |
| AC-3 N ≥ 24 per question × specs × 3 repeats, every metric | Harness done: 27 + 26 items, 2 specs, 3 repeats, all metrics computed. Model numbers pending the live run. |
| AC-4 go/no-go | Rule encoded. Not evaluable without a live run. |
| AC-5 1,600-token state | Client side done: a structured error, not a crash. Ollaya's behaviour pending. No follow-up ticket is needed for req_llm or ash_ai. |
| AC-6 `mix test` with no network | Done. 42 spike tests, all through Req plugs (14 of them cover the per-model host resolver). |
| AC-7 band table verifies clean | Done: no findings, no obligations. |
| AC-8 Luke reads this doc | Open. |

## Checks run

On `spike/system-one-0`:

- `mix compile --warnings-as-errors` and `mix format --check-formatted` pass.
- `mix credo --strict`, under both dev and test, reports nothing for the spike
  files.
- `mix dialyzer` passes after adding `:mix` to the PLT (`plt_add_apps: [:mix]`,
  the same one-line change CLIN-34 made).
- The spike tests (42) pass.
- The full suite has the 13 compliance failures, and `mix ash.codegen --check`
  reports the 20 pending ash_compliance and engine snapshot files. Both are
  pre-existing on `main`. None touch spike code, and the spike resource has no
  data layer.
- `reuse lint` passes.
