#!/usr/bin/env bash
# Spike-0 live run: record real fixtures from Ollaya, check the GPU is doing
# the work, then prove the recording replays.
#
#     scripts/spike0-live.sh                 # both specs, 3 repeats, cold run
#     SPECS=laya REPEATS=1 scripts/spike0-live.sh
#
# Reads ~/.config/system-one/endpoints.env (override with ENDPOINTS_ENV). The
# file's values are never printed and never written to fixtures or results.
#
# Variables the spike reads (see ClinicDemo.SystemOneSpike.Models):
#   OLLAYA_BASE_URL   e.g. http://laptop.tailnet:11435   (no /v1; required)
#   OLLAYA_API_KEY    if Ollaya was started with a key    (default "local")
# Optional:
#   OLLAYA_SSH        ssh target for the Ollaya box, e.g. luke@laptop. Enables
#                     the version/digest capture, `ollaya ps`, and the unload
#                     command for the cold run.
#   S1_GPU_MAX_MS     warm-request median above which a CPU fallback is
#                     suspected (default 400)
#   MIX               how to run mix (default "mix"; e.g. "devenv shell -- mix")
set -euo pipefail

cd "$(dirname "$0")/.."

ENDPOINTS_ENV="${ENDPOINTS_ENV:-$HOME/.config/system-one/endpoints.env}"
if [[ ! -f "$ENDPOINTS_ENV" ]]; then
  echo "missing $ENDPOINTS_ENV; nothing to run live against" >&2
  exit 2
fi
set -a
# shellcheck disable=SC1090
source "$ENDPOINTS_ENV"
set +a

# Accept a couple of likely spellings, without printing any of them.
OLLAYA_BASE_URL="${OLLAYA_BASE_URL:-${OLLAYA_URL:-${S1_OLLAYA_BASE_URL:-}}}"
OLLAYA_API_KEY="${OLLAYA_API_KEY:-${S1_OLLAYA_API_KEY:-local}}"
OLLAYA_SSH="${OLLAYA_SSH:-${S1_OLLAYA_SSH:-}}"
if [[ -z "$OLLAYA_BASE_URL" ]]; then
  echo "OLLAYA_BASE_URL is not set in $ENDPOINTS_ENV" >&2
  exit 2
fi
OLLAYA_BASE_URL="${OLLAYA_BASE_URL%/}"
OLLAYA_BASE_URL="${OLLAYA_BASE_URL%/v1}"
export OLLAYA_BASE_URL OLLAYA_API_KEY

MIX="${MIX:-mix}"
SPECS="${SPECS:-laya,winnow}"
REPEATS="${REPEATS:-3}"
GPU_MAX_MS="${S1_GPU_MAX_MS:-400}"
SET="live-$(date +%F)"
OUT="priv/fixtures/system_one/spike0/results/$SET"
mkdir -p "$OUT"

model_id() {
  case "$1" in
    laya) echo "laya:typed-decisions" ;;
    winnow) echo "winnow:e4b" ;;
    *) echo "unknown spec $1" >&2; exit 2 ;;
  esac
}

echo "== environment (recorded to $OUT/environment.txt; no secrets)"
{
  echo "date: $(date -Is)"
  echo "specs: $SPECS  repeats: $REPEATS"
  if [[ -n "$OLLAYA_SSH" ]]; then
    echo "ollaya --version: $(ssh "$OLLAYA_SSH" ollaya --version 2>&1 | head -1)"
    for spec in ${SPECS//,/ }; do
      echo "--- ollaya show $(model_id "$spec")"
      # shellcheck disable=SC2029 # the model id is meant to expand locally
      ssh "$OLLAYA_SSH" ollaya show "$(model_id "$spec")" 2>&1 | head -40
    done
  else
    echo "OLLAYA_SSH not set: Ollaya version and model digests NOT captured; fill them in by hand"
  fi
} | tee "$OUT/environment.txt"

if [[ -n "$OLLAYA_SSH" ]]; then
  S1_OLLAYA_VERSION="$(ssh "$OLLAYA_SSH" ollaya --version 2>&1 | head -1)"
  export S1_OLLAYA_VERSION
  export S1_OLLAYA_UNLOAD_CMD="ssh $OLLAYA_SSH ollaya stop {model}"
fi

echo "== GPU smoke test: warm latency of a one-question request"
smoke_fail=0
for spec in ${SPECS//,/ }; do
  model="$(model_id "$spec")"
  # shellcheck disable=SC2016 # the backticks are part of the question text
  body=$(printf '{"model":"%s","state":{"notes":"Recheck booked in 14 days."},"questions":{"q":{"type":"noul","instructions":"Do `notes` record a follow-up plan?"}}}' "$model")
  # First call loads the model; it is timed but not judged.
  code=$(curl -s -o "$OUT/smoke-$spec.json" -w '%{http_code} %{time_total}' \
    -H "authorization: Bearer $OLLAYA_API_KEY" -H 'content-type: application/json' \
    --max-time 180 -d "$body" "$OLLAYA_BASE_URL/v1/systemone" || echo "000 0")
  echo "$spec load: HTTP ${code% *}, ${code#* }s"
  if [[ "${code% *}" != "200" ]]; then
    echo "$spec: smoke request failed; reply in $OUT/smoke-$spec.json" >&2
    smoke_fail=1
    continue
  fi
  times=()
  for _ in 1 2 3 4 5; do
    t=$(curl -s -o /dev/null -w '%{time_total}' \
      -H "authorization: Bearer $OLLAYA_API_KEY" -H 'content-type: application/json' \
      --max-time 60 -d "$body" "$OLLAYA_BASE_URL/v1/systemone")
    times+=("$t")
  done
  median_ms=$(printf '%s\n' "${times[@]}" | sort -n | sed -n 3p | awk '{printf "%d", $1*1000}')
  echo "$spec warm median: ${median_ms} ms (threshold ${GPU_MAX_MS} ms)" | tee -a "$OUT/environment.txt"
  if (( median_ms > GPU_MAX_MS )); then
    echo "$spec: SLOW. Ollaya may have fallen back to CPU. Check 'ollaya ps' on the box." | tee -a "$OUT/environment.txt"
    smoke_fail=1
  fi
done
if [[ -n "$OLLAYA_SSH" ]]; then
  echo "--- ollaya ps (after smoke)" | tee -a "$OUT/environment.txt"
  ssh "$OLLAYA_SSH" ollaya ps 2>&1 | tee -a "$OUT/environment.txt" || true
fi
if (( smoke_fail )) && [[ "${FORCE:-0}" != "1" ]]; then
  echo "smoke test failed; not recording. FORCE=1 to record anyway." >&2
  exit 1
fi

echo "== record: every item, $REPEATS repeats, cold first"
$MIX clinic.spike0 --transport record --set "$SET" --specs "$SPECS" --repeats "$REPEATS" --cold

echo "== replay the recording (no network)"
$MIX clinic.spike0 --transport replay --set "$SET" --specs "$SPECS" --repeats "$REPEATS" --cold --out "$SET-replay"

echo
echo "Recorded: priv/fixtures/system_one/spike0/replay/$SET.jsonl"
echo "Results:  $OUT/summary.md  (paste into docs/spikes/system-one-spike-0.md, 'Live results')"
echo "Replay:   priv/fixtures/system_one/spike0/results/$SET-replay/summary.md (latency and answers must match)"
