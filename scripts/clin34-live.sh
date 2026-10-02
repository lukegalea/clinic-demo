#!/usr/bin/env bash
# CLIN-34 live run: smoke-test the endpoints, then record a fixture set.
#
#   scripts/clin34-live.sh [SET]        # default SET: recorded-YYYY-MM-DD
#
# Reads endpoint details from ~/.config/system-one/endpoints.env (override
# with S1_ENDPOINTS_ENV). The variables it needs are documented in
# ClinicDemo.EvidenceSpike.Models: S1_GEN_BASE_URL, S1_GEN_MODEL,
# S1_GEN_PROVIDER, S1_GEN_API_KEY, S1_GEN_REASONING_EFFORT, OLLAYA_BASE_URL,
# OLLAYA_API_KEY, S1_OLLAYA_ROUTES, S1_OLLAYA_GPU_BASE_URL.
# Never echo them: keys stay in the environment of this process.
#
# Step 1 is a smoke test on one certificate, live and unrecorded. Its gate
# is a THROUGHPUT gate, not a device probe: a 27B model decoding on CPU, or
# a verifier answering from the wrong host, is several times slower than the
# thresholds. That catches a silent CPU fallback. It cannot tell which GPU
# ran the model, so also check on the box itself (nvidia-smi, rocm-smi, or
# Activity Monitor's GPU history, and Ollaya's startup log for OLLAYA_DEVICE).
#
# Step 2 pins what answered: for every Ollaya host involved it records the
# model NAME and sha256 DIGEST from /api/tags and /api/ps, plus /api/version
# when the server offers it — names and digests only, never URLs or keys.
#
# Step 3 records a fixture set from N certificates (default 20) and writes the
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
# winnow answers from the GPU host's CPU (its llama.cpp; 1.4-2.2 s warm, see
# the endpoints probe of 2026-09-29), so 2500 ms passes that placement with
# headroom while still catching a true CPU fallback — a verifier served by
# the CPU host's Ollaya, several times slower, fails this gate.
MAX_WINNOW_MS="${CLIN34_MAX_WINNOW_MS:-2500}"
RESULTS="docs/research/clin-34-results-${SET}.json"
SMOKE="$(mktemp -t clin34-smoke.XXXXXX.json)"
ENV_RECORD="$(mktemp -t clin34-env.XXXXXX.json)"
trap 'rm -f "$SMOKE" "$ENV_RECORD"' EXIT

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

echo "== 2. provenance: model names and digests per Ollaya host (never URLs or keys)"
# The smoke warmed the models, so /api/ps shows what answered. Only NAME and
# sha256 DIGEST are kept; endpoint values stay in this process's environment
# and are never printed. A gap is recorded as an error marker, not silently.
python3 - "$ENV_RECORD" <<'PY'
import json, os, sys, urllib.request


def get(base, path, timeout=10):
    with urllib.request.urlopen(base.rstrip("/") + path, timeout=timeout) as resp:
        return json.load(resp)


def models(body):
    # Law 6: pin what answered — name and digest only.
    kept = []
    for m in body.get("models") or []:
        name, digest = m.get("name"), m.get("digest")
        if name:
            entry = {"name": name}
            if isinstance(digest, str) and digest.startswith("sha256:"):
                entry["digest"] = digest
            kept.append(entry)
    return kept


def host(label, base):
    record = {"host": label}
    for key, path in (("models", "/api/tags"), ("loaded", "/api/ps")):
        try:
            record[key] = models(get(base, path))
        except Exception as exc:
            record[key] = None
            record[key + "_error"] = type(exc).__name__
            # The exception message can carry the URL; print the class only.
            print(f"clin34-live: {label} host {path} unreachable ({type(exc).__name__})",
                  file=sys.stderr)
    try:
        version = get(base, "/api/version").get("version")
        if isinstance(version, str):
            record["version"] = version
    except Exception as exc:
        print(f"clin34-live: {label} host /api/version unavailable ({type(exc).__name__})",
              file=sys.stderr)
    return record


routes = os.environ.get("S1_OLLAYA_ROUTES", "")
hosts = [("cpu", os.environ.get("OLLAYA_BASE_URL", ""))]
if any(e.strip().lower().endswith("=gpu") for e in routes.split(",") if e.strip()):
    hosts.append(("gpu", os.environ.get("S1_OLLAYA_GPU_BASE_URL", "")))

with open(sys.argv[1], "w") as f:
    json.dump({"ollaya": [host(label, base) for label, base in hosts if base]}, f)
PY

echo "== 3. record: $N certificates into set $SET"
mix clin34.spike --mode record --set "$SET" --n "$N"

python3 - "$RESULTS" "$ENV_RECORD" <<'PY'
import json, sys
path, env_path = sys.argv[1], sys.argv[2]
with open(path) as f:
    summary = json.load(f)
with open(env_path) as f:
    summary["environment"] = json.load(f)
with open(path, "w") as f:
    json.dump(summary, f)
    f.write("\n")
print(f"environment record merged into {path}")
PY

echo "Replay it with: mix clin34.spike --set $SET"
