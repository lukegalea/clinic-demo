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

**Second labelling record (2026-10-02).** The blind second labelling ran per the S1-25 double-label
protocol: a second rater (an AI agent of this programme, ora-4 — accepted as second labeller of record per
the owner's 2026-10-02 proceed-as-recommended sweep; that acceptance is the adjudication of record for this
run) labelled all 53 items strictly blind (labels fixed before unblinding; inputs read via a
machine-verified label-free projection). Result: **53/53 raw agreement, zero disagreements — Cohen's kappa
= 1.000 in both families (noul p_e 0.53; choice p_e 0.22); PABAK = AC1 = 1.000 where the
<10%-prevalence rule triggers (combined-layer `insufficient`).** Zero items dropped, so no replay re-run
was required. Honest caveats, per the design's own kappa caveat: item ids encode their strata (anchoring
risk), and the second rater is an AI of the same programme that designed the set — kappa = 1.000 is an
**upper bound** for a truly independent second labeller; the informative content is that all 25 non-trivial
items (hard negatives, length probes, hard choice, abstentions) agreed, including every item flagged
medium-confidence before unblinding. The full pre-unblind working notes and contamination ledger are
preserved beside the items: `priv/fixtures/system_one/spike0/blind-second-labels-notes.md`.

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

**GPU-host llama.cpp first-load flakiness (2026-10-02).** On the GPU host,
`winnow:e4b` (and `jevk5:latest`) can fail their FIRST load after idle with a
ggml-cuda crash at load (HTTP 500 `MODEL_LOAD_FAILED`) instead of falling back
to CPU. Once any llama.cpp model has initialized on that host, subsequent
loads of `winnow:e4b` succeed and run warm at ≈1.0 s. Measured: first-load
failure twice from idle; then success after a derived CPU manifest
(`winnow-cpu:e4b`, created via `POST /api/create`
`{"model":"winnow-cpu:e4b","from":"winnow:e4b"}`, reusing the same weights
layer sha256 `840e3f50…` pinned in the licence audit) initialized the
backend; `winnow:e4b` itself then loaded normally. `jevk5:latest` remained
load-broken on this host. Practical guidance: warm winnow once before
trusting a smoke gate; a failed cold row (`cold_ok=false`) may be this
flakiness, not the spike.

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
   a curl `keep_alive: 0` POST to `/api/decide` on the model's own host.
   A failed unload is a warning, never fatal.
4. Replays the recording with no network, into `results/live-<date>-replay/`.
   The two summaries must match.

Then commit `replay/live-<date>.jsonl`, `results/live-<date>/`, and this
document with the template below filled in. Keep the stub set; CI replays it.

To preload on the laptop: `laya:typed-decisions` and `winnow:e4b`, with the
Ollaya version pinned. The smoke test's load request absorbs a cold load either
way.

## Live results (2026-10-02, set `live-2026-10-02`)

**Setup.** Recorded in one invocation, replayed clean (358 rows; provenance `recorded`). Ollaya **0.7.5**
on the CPU host (ONNX; `laya:typed-decisions`) and **0.9.0** on the M5 Pro (llama.cpp/Metal; `winnow:e4b`,
same weights digest as the 2080 Ti copy). Digests, captured over HTTP at call time per RFC S1-24 Q7:
laya `6d17e5fbcbb8215a74f2efd0dcc0ffdbd472e9b25ccb07867f9f146a791673ba`; winnow
`dd4bf88aa50bebb02e7a26fbebed14682befd037e3e89789ee22b9793f82d226`. Full history in
`results/live-2026-10-02/environment.txt` (the 2080 Ti host dropped out mid-session: its llama.cpp
loads crash for missing sm75 kernels and survive an Ollaya restart; winnow moved to the M5 Pro, warm
p50 117 ms against ~970 ms on the wedged host's CPU path).

**Wire compatibility.**

| Check | laya | winnow |
|---|---|---|
| `Result.model` populated? | `laya:typed-decisions` | `winnow:e4b` (digest from `/api/tags`//`/api/ps` at call time — the reply itself carries the name only, as Q7 records) |
| `usage` present? | 167/167 non-error rows | 179/179 |
| Noul / Choice / Judgments cast without error? | Yes; the 12 error rows are 422s, not cast failures | Yes, all rows |
| Overflow at ≈1,100 / 1,600 tokens | **422 structured error from ≈1,093 tokens** (1,024 context); no silent truncation, probe answers stable below | Clean through 1,586 tokens (8k context); separation holds |

**Metrics** (provenance: `recorded`, set `live-2026-10-02`, 3 repeats + cold).

Noul `notes_follow_up`:

| spec | N (answered/errors) | AUROC | mean p gold+ / gold− | median p gold+ / gold− | in 0.2–0.8 | ECE (10 bins) | Brier | acc @0.5 | sel @0.9 (cov / acc) | sel @0.8 (cov / acc) | lowest t with acc≥0.95, cov≥0.4 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| laya | 27 (23/4) | 0.983 | 0.703 / 0.434 | 0.697 / 0.402 | 22 | 0.269 | 0.170 | 0.739 | 0.000 / – | 0.043 / 1.000 | 0.650 (cov 0.478) |
| winnow | 27 (27/0) | 1.000 | 0.974 / 0.160 | 0.985 / 0.072 | 6 | 0.110 | 0.033 | 0.963 | 0.667 / 1.000 | 0.778 / 1.000 | 0.500 (cov 1.000) |

Choice `presenting_urgency`:

| spec | N | accuracy | ECE top-p | Brier top-p | sel @0.9 | sel @0.8 | band: suggested (acc) | abstained / gold abstain |
|---|---|---|---|---|---|---|---|---|
| laya | 26 | 0.462 | 0.276 | 0.298 | 0.000 / – | 0.000 / – | 0 (–) | 0 of 4 |
| winnow | 26 | 0.808 | 0.200 | 0.164 | 0.269 / 1.000 | 0.500 / 0.846 | 12 (0.833) | 4 of 4 |

Latency, batching and variance:

| spec | warm p50 / p95 ms (n) | cold first request ms | both vs separate ms | both: mean \|Δp\|, same choice | repeat stddev p |
|---|---|---|---|---|---|
| laya | 213.7 / 508.4 (147) | 3,277.4 | 603.5 vs 358.9 | 0.039, 11/19 | 0.000 / 0.000 |
| winnow | 117.0 / 252.5 (159) | 923.3 | 267.9 vs 343.1 | 0.119, 19/19 | 0.000 / 0.000 |

**Reliability** (bin, n, mean p, observed rate — most bins hold one or two items at this N):

| bin | laya n / mean p / obs | winnow n / mean p / obs |
|---|---|---|
| 0.0–0.1 | 0 / – / – | 9 / 0.045 / 0.0 |
| 0.1–0.2 | 1 / 0.163 / 0.0 | 2 / 0.153 / 0.0 |
| 0.2–0.3 | 3 / 0.266 / 0.0 | 4 / 0.234 / 0.0 |
| 0.3–0.4 | 3 / 0.359 / 0.0 | 0 |
| 0.4–0.5 | 2 / 0.440 / 0.0 | 1 / 0.470 / 0.0 |
| 0.5–0.6 | 2 / 0.557 / 0.0 | 1 / 0.598 / 0.0 |
| 0.6–0.7 | 8 / 0.641 / 0.5 | 0 |
| 0.7–0.8 | 4 / 0.745 / 1.0 | 0 |
| 0.8–0.9 | 0 | 1 / 0.896 / 1.0 |
| 0.9–1.0 | 0 | 9 / 0.983 / 1.0 |

**Recommendation.**
- **Default local instrument: `winnow:e4b` on the M5 Pro.** AUROC 1.000 on the noul, best separation and
  calibration of the two (ECE 0.110), selective accuracy 1.000 at 0.667 coverage, warm p50 117 ms, and it
  abstains on all four gold-abstain choice items. laya stays as the second instrument. Per the S1-23
  ruling (2026-10-02): these are prototype instruments in a model-agnostic architecture — a default here is
  an engineering choice for the substrate, never a product commitment or public-facing model branding.
- **laya's 1,024-token limit forces atom-sized state.** Confirmed: structured 422 from ≈1,093 tokens, no
  silent truncation. State for laya-sized instruments must be atom-sized; this feeds the compliance track's
  atomiser.
- **Batching changes answers for laya, not for winnow.** Mean |Δp| 0.039 (laya) flips laya's choice on 8 of
  19 pairs at the 0.5 boundary; winnow shifts by 0.119 without ever flipping (19/19). Latency: laya is
  slower batched (603 vs 359 ms), winnow slightly faster. Conclusion: record the batching mode in the
  observation; avoid boundary-sensitive judgments on laya in `both` mode.
- Calibration is **not** settled: ECE 0.110 (winnow) / 0.269 (laya) are family-level measurements on N=27,
  not band tables. Bands are earned per family per the eval-set programme (S1-25); no auto-admission may
  cite these numbers or any shipped calibration.

## Go / no-go (AC-4)

The decision rule, fixed before any model ran:

> **Go** for building the substrate only if at least one local spec reaches,
> on the noul: AUROC ≥ 0.85, selective accuracy ≥ 0.95 at a coverage of at
> least 40% for some threshold, and warm p95 latency ≤ 250 ms. Otherwise
> **no-go** or **go-with-conditions**, with reasons. The same numbers are
> reported for the choice.

The ticket's 250 ms bar was written for a CPU host. The spike now runs on a GPU
box, so the bar stands as written.

**Outcome: go, with one condition recorded.** Against the rule:

| spec | AUROC ≥ 0.85 | selective acc ≥ 0.95 @ cov ≥ 0.4 | warm p95 ≤ 250 ms |
|---|---|---|---|
| laya | 0.983 ✓ | ✓ (t 0.650, cov 0.478) | 508.4 ms ✗ |
| winnow | 1.000 ✓ | ✓ (t 0.9, cov 0.667, acc 1.000; t 0.500 gives cov 1.000) | **252.5 ms — over by 2.5 ms (1%)** |

winnow clears the discrimination and selectivity bars decisively and misses the latency bar by 1%:
the p95 window (159 requests) includes the first warm requests after the cold leg; standalone warm
probes on the M5 Pro measured 73–80 ms. **Condition:** accept the 1% overshoot as post-cold warm-up, or
re-measure warm-only at Luke's leisure; nothing else about the verdict changes. The runner's own
encoded verdict — "no-go or go-with-conditions (see doc)" — is hereby read as **go with that condition**,
plus the standing framing condition from the S1-23 ruling (prototype instruments, model-agnostic
architecture, no public model branding).

## First calibration over the calibration split (2026-10-03, S1-25)

The eval-sets harness is wired to the spike (`mix clinic.calibrate`,
`ClinicDemo.SystemOneSpike.Calibration`): it drift-checks the §6 split
companion, runs the spike's own call path over the **calibration
split** — 33 items, `noul` 17 / `choice` 16 — and records the results
as a calibrate-compatible artefact: the §8.1 run map per
`(spec, family)`, field-for-field what `ash_judgments`' CalibrationRun
store records (clinic-demo does not depend on `ash_judgments`; this is
the package-compatible producer, format pinned by tests).

First run: 2026-10-03 00:20, transport `record:calibration-2026-10-02`
(one complete replayable fixture set, provenance `recorded` on all 66
exchanges), one answer per item, both specs, α = 0.016, min_n = 62,
region `homelab`. Both models unloaded after the run (`POST /api/decide`,
`keep_alive: 0`, both 200).

| spec / family | n answered | ece | brier | accuracy | λ̂ at α | result |
|---|---|---|---|---|---|---|
| laya / notes_follow_up | 14 | 0.301 | 0.185 | — | none qualifies | `no_table` |
| laya / presenting_urgency | 16 | — | — | 0.500 | none qualifies | `no_table` |
| winnow / notes_follow_up | 17 | 0.134 | 0.045 | — | none qualifies | `no_table` |
| winnow / presenting_urgency | 16 | — | — | 0.813 | none qualifies | `no_table` |

Readings, stated plainly:

- **Every run keeps its negative result.** At n ≈ 16 the conformal
  bound does its job: even zero errors gives 1/(n+1) ≈ 0.06 > α = 0.016,
  so no λ̂ qualifies and nothing is proposed. This is the design working,
  not a failure — a band table needs the family's min_n (62 at e = 0)
  before it can be earned.
- **laya's 3 missing noul answers are the length probes**
  (`n-len-1100-neg`, `n-len-1600-pos`, `n-len-1600-neg`): structured
  422s ("part of state was dropped to fit the context"), consistent
  with AC-5's record — laya tops out at ≈1,093 tokens. The split's §6
  draw put those items in calibration; they count as errors here, not
  silent drops. winnow answered everything.
- **Early signal, n too small to trust:** winnow is well ahead on both
  families (noul ECE 0.134 vs 0.301; choice accuracy 0.813 vs 0.500 —
  laya's emergency/insufficient recalls are 0.0). The next calibration
  re-runs the same command against the same companion; the accumulated
  fixture sets make any re-scoring replayable.

Artefact: `priv/fixtures/system_one/spike0/results/calibration-2026-10-02/`
(`calibration.json` — the §8.1 run maps; `rows.jsonl` — the raw rows;
`summary.md`). Fixture set: `replay/calibration-2026-10-02.jsonl`.

## Acceptance status

| AC | Status |
|---|---|
| AC-1 Ollaya noul, `Result.model` recorded | **Done live.** `Result.model` populated on both specs; digest provenance via HTTP capture at call time (RFC Q7). |
| AC-2 hosted Jev | Removed from scope (DEC-HOSTED "never"). A static grep test guards against `-latest`. |
| AC-3 N ≥ 24 per question × specs × 3 repeats, every metric | **Done.** 27 + 26 items, 2 specs, 3 repeats + cold, all metrics recorded live (set `live-2026-10-02`, replay verified). |
| AC-4 go/no-go | **Evaluated: go, with one condition** (winnow's warm p95 252.5 ms vs the 250 ms bar — 1% over, post-cold warm-up in window; standalone warm probes 73–80 ms). See the Go/no-go section. |
| AC-5 1,600-token state | **Done live.** laya: structured 422 from ≈1,093 tokens (1,024 context), no silent truncation; winnow clean through 1,586. No req_llm/ash_ai follow-up needed. |
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
