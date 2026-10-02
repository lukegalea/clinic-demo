# CLIN-34: extract-then-verify on synthetic certificates

**Status (2026-09-28): the harness is built and verified. It has not yet been run against a model.** The live
endpoints were not configured when this was written, so every number below comes from the **stub**. Stub numbers
test the harness, not a model. The live command is ready; see "Running it live".

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
| AC-1 (eval): the fabricated-citation rate is reported for both paths, N ≥ 20 | `mix clin34.spike` computes it from the ledger for `static` and `enum`. The test replays the committed stub set with N = 20 and asserts that `enum` reports 0 and that `static` reports a rate. | **Mechanism verified; the model result is still open.** In the stub, `enum` = 0 by construction. Whether llama-server's grammar actually enforces the enum is the question the live run answers. |
| AC-2 (unit): a regex- or length-violating reply is rejected and recorded, not repaired | Two tests. (1) The stub plants the malformed policy number `CLV-12AB` on certificate 9. The prompt action's cast rejects it, the `extraction` row records `passed: false` along with the error and the raw reply, and no proposal rows are written. (2) A 121-character insured name is rejected by the same two-step cast. | Passing |
| AC-3 (static): no confidence field, and every enum carries an abstention value | Tests walk the exact schema sent: no `confidence` key anywhere; `status` includes `not_found`/`ambiguous`; `coverage_type` includes `not_stated`; `source_ids` may be empty. A further test proves that `static_schema/0` is the schema the prompt action really sends: the committed stub fixtures were keyed from the prompt action's own payload, and the key computed from `static_schema/0` is found among them. | Passing |

Wire tests capture the outgoing request with a Req adapter; no request leaves the process. They show the per-call enum
reaching an OpenAI-compatible server as `response_format: json_schema`, with
`source_ids.items.enum == ["a01", "a02"]` and no `tools`. They show the verifier going to
`OLLAYA_BASE_URL/v1/systemone`. And they show that no fixture carries a URL or a key.

## Stub results (harness only, N = 20)

These are the stub's **planted** faults, recovered by the metrics. They show that the measurement works. They say
nothing about Qwen, laya or winnow.

| | static | enum |
|---|---|---|
| cast failures | 2 / 20 (the planted `CLV-12AB`, certificates 9 and 18) | 2 / 20 |
| exact match, of cast proposals | 0.986 | 0.986 |
| exact match, of all fields | 0.888 | 0.888 |
| extractions with a fabricated citation | 2 / 18 (certificates 6 and 12 cite `a99`) | **0 / 18** (the stub, like a grammar, can only say ids in the enum) |
| checks failed | `citations_in_packet` × 2 | none |
| verifier questions asked / answerable | 136 / 134 (2 cite only `a99`, so there is nothing to ask) | 136 / 136 |
| wrong proposals flagged at p < 0.5 | 2 / 2 (the broker-licence misreads on certificates 7 and 14, on both verifiers) | 2 / 2 |

Latency is 0 ms in the stub. Full summary: `docs/research/clin-34-results-stub.json`.

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
passes the GPU host's CPU placement (1.4–2.2 s) and fails a true CPU fallback.

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

- **The numbers.** Exact match, cast failures, fabricated citations with and without the enum, verifier agreement and
  latency, all from the live run.
- **The constraint tax** (the ticket's open question): does Qwen under grammar produce valid but wrong values? If it
  does, try reason-then-serialise.
- **Band tables.** The verifier's probability is recorded but not banded. `agreement_at_0_5` is a fixed 0.5 cut for
  reporting only. DMN band tables come with calibration (W2/W3).
- **Scaling to 60 certificates.** `--n 60` works. The stub set is recorded at 20.
