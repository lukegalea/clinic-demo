#!/usr/bin/env bash
# CLIN-34 live run: smoke-test the endpoints, then record a fixture set.
#
#   scripts/clin34-live.sh [SET]        # default SET: recorded-YYYY-MM-DD
#
# Reads endpoint details from ~/.config/system-one/endpoints.env (override
# with S1_ENDPOINTS_ENV). The variables it needs are documented in
# ClinicDemo.EvidenceSpike.Models: S1_GEN_BASE_URL, S1_GEN_MODEL,
# S1_GEN_PROVIDER, S1_GEN_API_KEY, OLLAYA_BASE_URL, OLLAYA_API_KEY.
# Never echo them: keys stay in the environment of this process.
#
# Step 1 is a smoke test on one certificate, live and unrecorded. Its gate
# is a THROUGHPUT gate, not a device probe: a 27B model decoding on CPU, or
# winnow:e4b answering on CPU, is several times slower than the thresholds.
# That catches Ollaya's silent CPU fallback. It cannot tell which GPU ran the
# model, so also check on the box itself (nvidia-smi, rocm-smi, or Activity
# Monitor's GPU history, and Ollaya's startup log for OLLAYA_DEVICE).
#
# Step 2 records a fixture set from N certificates (default 20) and writes the
# summary to docs/research/clin-34-results-SET.json. Only synthetic
# certificates are sent; the fixtures hold model labels, never URLs or keys.
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE="${S1_ENDPOINTS_ENV:-$HOME/.config/system-one/endpoints.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "clin34-live: $ENV_FILE is missing; nothing to run against." >&2
  echo "Replay the committed stub set instead: mix clin34.spike" >&2
  exit 2
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${S1_GEN_BASE_URL:?S1_GEN_BASE_URL must be set in $ENV_FILE}"
: "${OLLAYA_BASE_URL:?OLLAYA_BASE_URL must be set in $ENV_FILE}"

SET="${1:-recorded-$(date +%F)}"
N="${CLIN34_N:-20}"
MIN_TOKS="${CLIN34_MIN_TOKENS_PER_S:-8}"
MAX_WINNOW_MS="${CLIN34_MAX_WINNOW_MS:-2500}"
SMOKE="$(mktemp -t clin34-smoke.XXXXXX.json)"
trap 'rm -f "$SMOKE"' EXIT

echo "== 1. smoke: one certificate, live, not recorded"
mix clin34.spike --mode live --n 1 --paths enum --out "$SMOKE" >/dev/null

python3 - "$SMOKE" "$MIN_TOKS" "$MAX_WINNOW_MS" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
min_toks, max_ms = float(sys.argv[2]), float(sys.argv[3])
path = summary["paths"]["enum"]
failures = []
if path["cast_failures"]:
    failures.append("the extraction did not cast; see the smoke summary")
toks = path.get("extract_output_tokens_per_s_median")
print(f"extractor {summary['extractor']}: {toks} output tokens/s (gate >= {min_toks})")
if toks is None or toks < min_toks:
    failures.append("extractor throughput below the GPU gate (or usage not reported)")
for model, v in path["verifiers"].items():
    ms = v["latency_ms_median"]
    print(f"verifier {model}: {v['answered']}/{v['asked']} answered, median {ms} ms")
    if v["answered"] == 0:
        failures.append(f"{model} answered nothing")
    if "winnow" in model and (ms is None or ms > max_ms):
        failures.append(f"{model} slower than {max_ms} ms: likely CPU fallback")
if failures:
    print("SMOKE FAILED:\n  " + "\n  ".join(failures))
    sys.exit(1)
print("smoke passed")
PY

echo "== 2. record: $N certificates into set $SET"
mix clin34.spike --mode record --set "$SET" --n "$N"
echo "Replay it with: mix clin34.spike --set $SET"
