# CLIN-34: extract-then-verify on synthetic certificates

**Status (2026-10-02): run live, end to end.** The harness was built and stub-verified on 2026-09-28, then recorded
against Splash, laya and winnow on 2026-10-02 (N = 20, both paths, both verifiers). The recorded set replays
offline; every number in the results sections below is from that live run. The stub run remains in
`docs/research/clin-34-results-stub.json` and the committed `stub` fixture set as harness verification only.

This is the public, synthetic twin of the evidence pipeline (ash_enterprise ADR 0044 and ADR 0046). It runs the
pipeline from the System One typed-output research: a generative model proposes values under a schema derived from
an Ash type; Ash re-casts them; deterministic checks run; a decision model verifies each proposal with one closed
question; and every rung writes its own ledger row.

Only synthetic data is used. The certificates are generated from fixed lists of invented names, insurers and amounts,
and every insurer name carries "(fictional)".

## What it is

| Piece | Where | What it does |
|---|---|---|
| Certificates | `lib/clinic_demo/evidence_spike/certificates.ex` | Seeded generator for clinician liability-insurance certificates. Each one is a packet of atoms (`a01`, `a02`, ...) with gold values. It plants three cases: a missing aggregate limit (every 4th), a contradictory aggregate limit (every 5th), and distractors (a broker-licence number shaped like a policy number, and a quote date). |
| Extraction type | `extraction.ex`, `proposal.ex` | An `Ash.TypedStruct`. Every field is `{value, status: found\|not_found\|ambiguous, source_ids}`, with **no confidence field**. The struct is the schema. |
| Static path | `extractor.ex`, `:extract` | An `ash_ai` prompt action returning the struct. `AshAi.Actions.Prompt` derives the wire schema and casts the reply. The schema is the same for every packet. |
| Per-call path | `Extractor.extract_with_enum/2` | Host code. It sends the same schema, with each `source_ids` narrowed to an enum of this packet's atom ids, through `generate_object/4`, and casts the reply through the same type. |
| Verifier | `extractor.ex`, `:verify` | An `ash_ai` evaluate action returning a Noul: *does the text in `atoms` state that the policy number is `CLV-1234567`?* Only the cited atoms are sent, which keeps each question inside laya's 1,024-token context. |
| Checks | `Runner.checks/2` | Dates in order; aggregate ≥ each-claim; every citation is in the packet; every `found` proposal has a citation. |
| Ledger | `observation.ex` | ETS rows of four kinds: `extraction` (raw reply, schema hash, model label, provenance, latency, output tokens, cast result), `proposal`, `check` and `verification`. Answers are inputs to a create action, so a replay never re-queries a model. |
| Record/replay | `wire.ex` | DEC-REPLAY. It sits behind `ash_ai`'s `req_llm:` option, with modes `live`, `record`, `replay` and `stub`. Fixtures are JSONL, keyed by a hash of the operation, the model label, and the exact schema or questions and prompt. Each fixture is labelled `recorded` or `stub`. |
| Models | `models.ex` | Tuple model specs from the environment (`base_url` in the tuple, as ReqLLM needs). |
| Task | `mix clin34.spike` | Runs N certificates through both paths and both verifiers, then writes the summary JSON. |

No HTTP client was written. Every model call goes through ReqLLM, via `AshAi.Actions.Prompt`, `AshAi.Actions.Evaluate`
or `ReqLLM.generate_object/4`.

## Acceptance

| AC | How it is checked | State |
|---|---|---|
| AC-1 (eval): the fabricated-citation rate is reported for both paths, N ≥ 20 | `mix clin34.spike` computes it from the ledger for `static` and `enum`. The test replays the committed stub set with N = 20 and asserts that `enum` reports 0 and that `static` reports a rate. | **Answered live (2026-10-02): 0 on both paths.** The per-call enum fabricated no citation, as hoped; the static path also fabricated none. Details in "Live results". |
| AC-2 (unit): a regex- or length-violating reply is rejected and recorded, not repaired | Two tests. (1) The stub plants the malformed policy number `CLV-12AB` on certificate 9. The prompt action's cast rejects it, the `extraction` row records `passed: false` along with the error and the raw reply, and no proposal rows are written. (2) A 121-character insured name is rejected by the same two-step cast. | Passing |
| AC-3 (static): no confidence field, and every enum carries an abstention value | Tests walk the exact schema sent: no `confidence` key anywhere; `status` includes `not_found`/`ambiguous`; `coverage_type` includes `not_stated`; `source_ids` may be empty. A further test proves that `static_schema/0` is the schema the prompt action really sends: the committed stub fixtures were keyed from the prompt action's own payload, and the key computed from `static_schema/0` is found among them. | Passing |

Wire tests capture the outgoing request with a Req adapter; no request leaves the process. They show the per-call enum
reaching an OpenAI-compatible server as `response_format: json_schema`, with
`source_ids.items.enum == ["a01", "a02"]` and no `tools`. They show the verifier going to
`OLLAYA_BASE_URL/v1/systemone`. And they show that no fixture carries a URL or a key.

## Live results (2026-10-02)

Splash (`openai:incoai/Qwen3.8-27B-Splash`, `reasoning_effort: none`) extracted; laya (`laya:typed-decisions`) and
winnow (`winnow:e4b`) verified, each asked one Noul per found proposal. N = 20 certificates × 8 fields × 2 paths,
both verifiers. The set `recorded-2026-10-02` replays offline: `mix clin34.spike --set recorded-2026-10-02`
(replay needs `S1_GEN_MODEL` set to the recorded id, since the model label is part of the fixture key).
Full summary: `docs/research/clin-34-results-recorded-2026-10-02.json`.

| | static | enum |
|---|---|---|
| cast failures | 0 / 20 | 0 / 20 |
| exact match, of all fields | 0.8375 | 0.8812 |
| by field | dates 0.80/0.80, aggregate 1.0, coverage 0.9, policy 1.0, name 1.0, per-claim 1.0, **insurer 0.2** | dates 1.0/1.0, aggregate 0.9, coverage 1.0, policy 1.0, name 0.95, per-claim 1.0, **insurer 0.2** |
| extractions with a fabricated citation | **0** | **0** (AC-1) |
| checks failed | `found_is_cited` × 1 | none |
| verifier questions asked / answered | 143 / 142 (1 unanswerable) | 154 / 154 |
| verifier–gold agreement at the 0.5 cut | 0.8873 | 0.8831 |
| wrong proposals / flagged at p < 0.5 | 16 / 0 | 19 / 1 |
| extract latency median | 5.1 s | 4.8 s |
| extractor output tokens/s | 75.2 | 85.7 |
| verifier latency median | laya 133 ms, winnow 2,052 ms | laya 135 ms, winnow 2,052 ms |

Latency per stage: extraction dominates (about 5 s per certificate; both paths send the whole packet); each verifier
question is 133–135 ms on laya and about 2 s on winnow — 296 winnow questions at 2.05 s each is about 10 minutes of
model time. The smoke gate held: the extractor decoded at 75–86 output tokens/s (gate ≥ 8) and winnow answered at
2.05 s median (gate ≤ 2.5 s).

**Fabricated citations: 0 on both paths.** The enum path's `source_ids` enum did its job; the static path — with no
per-call narrowing — also fabricated nothing. Every citation landed inside the packet.

**The verifier story is separation, not agreement.** Both verifiers agree with gold about 88% of the time, but they
almost never *flag*: at the fixed 0.5 cut, 1 of 19 wrong enum proposals and 0 of 16 wrong static proposals scored
below 0.5. Mean p on wrong proposals is 0.62–0.94 depending on verifier and path — a "yes" lean. The fixed cut is a
reporting device, not a calibrated detector; the band tables (W2/W3) have real work to do.

**The insurer 0.2 is a gold-label artifact, not an extraction error.** Both paths land on 4 / 20 exact matches for
one reason: the generator appends the synthetic-data marker `"(fictional)"` to every insurer name, and gold keeps
it, while Splash drops the parenthetical in 16 of 20 extractions on each path. The extracted names are otherwise
correct and correctly cited to the insurer atom: `"Insurer: Maple Tier Professional Underwriters (fictional)"`
comes back as `"Maple Tier Professional Underwriters"`, `"Lakeshore Clinician Assurance (fictional)"` as
`"Lakeshore Clinician Assurance"`, and so on. The marker is preserved stochastically (different certificates on
each path), which is why the two paths agree on the rate but not on which certificates pass. The wrong side is the
gold label: a provenance marker baked into the compared value. Future runs should strip `"(fictional)"` on both
sides before the exact-match comparison (a metric/gold change, deliberately not made before this recorded run).

Provenance: the run went through `scripts/clin34-live.sh` on 2026-10-02, which captured an environment record at
record time — model NAME and sha256 DIGEST per involved Ollaya host (the CPU host serving laya, the GPU host's CPU
serving winnow) and Splash — from `/api/tags`, `/api/ps` and `/api/version`, with no URLs or keys. The committed
results JSON is the offline replay regeneration (`"mode": "replay"`, identical metrics; replay carries the
recorded latencies and token counts in the fixtures). The record-mode copy of the summary, which held the digest
record, was overwritten by that replay; the digests are restored below from the same-day, same-host capture in
the spike-0 run (S1-21, `results/live-2026-10-02/environment.txt` on `spike/system-one-0`):

- Ollaya `0.7.5` on both hosts.
- `laya:typed-decisions` (CPU host): sha256 `6d17e5fbcbb8215a74f2efd0dcc0ffdbd472e9b25ccb07867f9f146a791673ba`.
- `winnow:e4b` (GPU host): sha256 `dd4bf88aa50bebb02e7a26fbebed14682befd037e3e89789ee22b9793f82d226`.
- Splash served `incoai/Qwen3.8-27B-Splash` (the model label is part of the fixture key; replay requires
  `S1_GEN_MODEL=incoai/Qwen3.8-27B-Splash`).

### Does the constraint tax exist?

The ticket's question: does schema-constrained output give *valid but wrong* values? At N = 20: yes, on both
paths, in different shapes — and nothing invalid ever arrived (0 cast failures in 40 extractions; the grammar and
the Ash re-cast held everywhere).

- **The per-call enum path** answered two of the planted aggregate traps *wrongly but validly*: on certificate 8
  (aggregate omitted) it reported CAD $5,000,000 citing the each-claim atom, and on certificate 20 (two
  contradictory limits) it resolved the contradiction to CAD $8,000,000 citing only one of the two atoms. Both
  replies satisfied the enum, the cast and every field constraint. The static path abstained correctly on both
  traps.
- **The static path** produced the run's one incoherent proposal: certificate 11's coverage type with
  `status: "found"`, `value: "not_stated"`, and no citation — every part schema-legal, the whole contradictory.
  It failed `found_is_cited` (the run's only check failure) and was the run's single unanswerable verification
  (nothing cited, so there was nothing to ask). The static path also abstained `not_found` on both dates for
  certificates 2, 9, 14 and 19, although the packet's date atom states them plainly — 8 valid false abstentions
  where the enum path extracted all 40 date fields correctly.

So the data shows: the constrained enum path eliminates fabrication and false abstentions but *invents under
pressure* (2 / 2 traps resolved into confident wrong values); the unconstrained static path abstains more but
sometimes abstains wrongly or contradicts itself. What it cannot show at N = 20 is which behaviour wins: 1–2
events per path per failure mode is noise, and the insurer marker artifact excludes one field in eight from exact
comparison entirely. Rank the paths at N = 60 with the gold-label fix before believing either direction.

## Findings from building it

These hold regardless of the model.

1. **ReqLLM's OpenAI provider does not send `response_format: json_schema` for a model id it does not know.** Under
   the default `:auto` mode, a local model id that is not in LLMDB (`qwen3.8-27b`) gets a forced tool call instead.
   `openai_structured_output_mode: :json_schema` is read only as a **top-level call option**. As a tuple default it is
   ignored, and so is `provider_options: [...]`. `:api_key` as a tuple default is dropped, with a warning, for
   `generate_object`. `Wire` moves both into the call options. `ash_ai`'s prompt action cannot set them per call from
   runtime config (its `req_llm_opts` are fixed at compile time), which is another reason the seam sits in `Wire`.
2. **`AshAi.OpenApi` renders a `TypedStruct` as `{}` unless it is given the struct's initialised constraints.** The
   prompt action is fine, because Ash initialises an action's return constraints at compile time. Host code that
   derives "the same" schema from the bare type silently gets an unconstrained object. `Extractor.static_schema/0`
   reads the action's constraints for this reason. This belongs with the upstream typed-output tickets (AST-126 to
   AST-131).
3. **Some refinements never reach the wire.** The schema carries enums, `format: date`, integer `minimum`/`maximum`
   and `required`. It carries no `pattern` for a `match` constraint and no string length bounds. So the policy-number
   regex and the 120-character limit are enforced only when Ash re-casts. That is why the cast failure has to be
   recorded rather than repaired (AC-2).
4. **One question per proposal, carrying only the cited atoms,** keeps laya inside its 1,024-token context. A
   proposal whose only citation is fabricated leaves nothing to verify. The ledger records it as unanswerable instead
   of asking about the whole packet.

## Running it live

The three dev-zone boxes are: Ollaya on the laptop, Lemonade embeddings on the 7700 XT, and Qwen3.8-27B on the M5 Pro.
This spike uses the first and the last. The embeddings box is not involved.

Preload:

- **Ollaya:** `laya:typed-decisions` and `winnow:e4b`. Pin the Ollaya version and the model digests (law 6).
- **M5 Pro:** Qwen3.8-27B, behind an OpenAI-compatible `/v1/chat/completions` that honours
  `response_format: {type: "json_schema"}` with enums. llama-server does, and so do LM Studio and
  vLLM. For Ollama, set `S1_GEN_PROVIDER=ollama`.

Put these in `~/.config/system-one/endpoints.env`:

```sh
S1_GEN_PROVIDER=openai          # openai | ollama | lmstudio | vllm
S1_GEN_BASE_URL=http://<m5-pro>:<port>/v1
S1_GEN_MODEL=<model id as the server names it>
S1_GEN_API_KEY=<if the server wants one>
OLLAYA_BASE_URL=http://<laptop>:11435
OLLAYA_API_KEY=<if OLLAYA_API_KEY is set on the server>
```

Then run:

```sh
scripts/clin34-live.sh                  # smoke (1 certificate), then record recorded-YYYY-MM-DD with N=20
mix clin34.spike --set recorded-YYYY-MM-DD   # replay it, offline
```

The smoke gate is a throughput gate, not a device probe:

- the extractor must decode at ≥ 8 output tokens/s (`CLIN34_MIN_TOKENS_PER_S`);
- winnow must answer in ≤ 2.5 s (`CLIN34_MAX_WINNOW_MS`).

A silent CPU fallback fails the gate. The gate cannot tell which GPU ran the model, so also confirm on the boxes.

## Host routing (2026-10-02)

The single-host assumption above is out of date. Following the endpoints probe of 2026-09-29, the dev zone routes
per model (`S1_OLLAYA_ROUTES`, comma-separated `model=CPU|GPU` in `endpoints.env`):

- **CPU host (`OLLAYA_BASE_URL`):** the small ONNX encoders — nli, gliclass, laya, von, kev, decision, qwen3guard.
  `laya:typed-decisions` (the first verifier) stays here.
- **GPU host (`S1_OLLAYA_GPU_BASE_URL`):** the vision decider, alone on the GPU; `winnow:e4b` and `jevk5` run on
  **its CPU**, because only that host has llama.cpp (warm: 1.4–2.2 s and about 2 s). Its CUDA path fails for this
  card's architecture.

`Models.verifier/1` resolves the route per model; with `S1_OLLAYA_ROUTES` unset everything stays on
`OLLAYA_BASE_URL`, so replay, stub and CI are unaffected. The `MAX_WINNOW_MS=2500` smoke gate still holds: it
passes the GPU host's CPU placement (1.4–2.2 s) and fails a true CPU fallback. The live run used the route as
configured: `winnow:e4b` answered from the GPU host at 2,052 ms median across its 297 questions, inside the probe's
warm band; first-load variance on that host is the band-separation spike's (Spike 0, S1-21) to measure.

**Splash must not reason for this spike.** It reasons by default and reasoning tokens count against `max_tokens`,
which starves the structured output. Set `S1_GEN_REASONING_EFFORT=none` in `endpoints.env`; `Models.extractor/0`
sends it as ReqLLM's native `reasoning_effort` call option and the server reports 0 reasoning tokens. The other
disable spellings (`chat_template_kwargs.enable_thinking=false`, `think:false`, `reasoning.enabled=false`,
`/no_think`, `thinking.type=disabled`) are all ignored by Splash.

**Standing rules for future image work** (from the same probe; recorded here so they are not re-derived — not yet
implemented in this spike):

- Images go to `decider:2b-vision` as **region crops of at most 0.5 MP**. Larger images (0.8 MP or more) fail with
  an ONNX Runtime out-of-memory error, and a crop is more decisive than a shrunken page (0.034 against 0.219 on the
  limits question). The decider must be the sole model on the GPU, or it silently falls back to CPU (201 s cold).
- Image embeddings go only through llama.cpp `multimodal_data` with the server's `media_marker` read from
  `GET /props` (the marker is randomised per server; the generic `<__media__>` fails to tokenize). **Never** the
  legacy `image_data` form: it returns a vector but silently ignores the image — every image gets the identical
  vector, equal to the embedding of the literal marker text.

## Still open

- **The numbers** are in ("Live results (2026-10-02)"); what remains of them is ranking the paths at a larger N.
- **The constraint tax** is answered at N = 20 (see the subsection): valid-but-wrong output exists on both paths,
  in different shapes. Whether reason-then-serialise beats either path is untested.
- **Band tables.** The live run sharpened the need: at a fixed 0.5 cut the verifiers flag almost nothing (1 of 35
  wrong proposals), so calibration matters more, not less. DMN band tables come with calibration (W2/W3).
- **The insurer gold label.** Strip `"(fictional)"` on both sides of the exact-match comparison (a metric change;
  deliberately not made before the recorded run).
- **Scaling to 60 certificates.** `--n 60` works. The recorded set here is at 20; re-record at 60 to rank the
  paths.
