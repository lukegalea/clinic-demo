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
#   OLLAYA_BASE_URL          CPU host, e.g. http://box.tailnet:11435 (no /v1; required)
#   S1_OLLAYA_GPU_BASE_URL   GPU host, same shape (required when a run model routes there)
#   S1_OLLAYA_ROUTES         per-model host map, e.g. laya:typed-decisions=CPU,winnow:e4b=GPU
#   OLLAYA_API_KEY           if Ollaya was started with a key    (default "local")
# Optional:
#   OLLAYA_SSH        ssh target for an Ollaya box. Adds the ssh `ollaya show`
#                     capture. Version and digests are captured over HTTP
#                     regardless (RFC S1-24 Q7), so this is no longer needed.
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

# Per-model host routing, mirroring ClinicDemo.SystemOneSpike.Models:
# S1_OLLAYA_ROUTES is comma-separated model=CPU|GPU; with it unset, every
# model lives on OLLAYA_BASE_URL. Callers capture the URLs with $(route_base
# ...); they are never echoed to the terminal or written to any result file.
route_target() {
  local model="$1" entry target=""
  if [[ -n "${S1_OLLAYA_ROUTES:-}" ]]; then
    for entry in ${S1_OLLAYA_ROUTES//,/ }; do
      if [[ "${entry%%=*}" == "$model" ]]; then
        target="${entry#*=}"
        break
      fi
    done
    if [[ -z "$target" ]]; then
      echo "S1_OLLAYA_ROUTES is set but names no host for $model; add $model=CPU or $model=GPU" >&2
      exit 2
    fi
  fi
  case "${target^^}" in
    "" | CPU) echo CPU ;;
    GPU) echo GPU ;;
    *)
      echo "S1_OLLAYA_ROUTES routes $model to '$target'; expected CPU or GPU" >&2
      exit 2
      ;;
  esac
}

host_base() {
  case "$1" in
    CPU) echo "${OLLAYA_BASE_URL%/}" ;;
    GPU)
      if [[ -z "${S1_OLLAYA_GPU_BASE_URL:-}" ]]; then
        echo "S1_OLLAYA_ROUTES routes a run model to GPU but S1_OLLAYA_GPU_BASE_URL is not set" >&2
        exit 2
      fi
      echo "${S1_OLLAYA_GPU_BASE_URL%/}"
      ;;
    *) echo "unknown host label $1" >&2; exit 2 ;;
  esac
}

route_base() {
  host_base "$(route_target "$1")"
}

# HTTP provenance (RFC S1-24 Q7): for each host this run's models route to,
# GET /api/version, /api/tags and /api/ps, and keep each run model's name,
# sha256 digest and size_vram. Everything collected here is written to
# environment.txt; URLs and keys never are.
http_provenance=""
declare -A host_done=()
for spec in ${SPECS//,/ }; do
  host="$(route_target "$(model_id "$spec")")"
  [[ -n "${host_done[$host]:-}" ]] && continue
  host_done[$host]=1
  base="$(host_base "$host")"
  tags="$(curl -s -H "authorization: Bearer $OLLAYA_API_KEY" --max-time 10 "$base/api/tags" || true)"
  ps_json="$(curl -s -H "authorization: Bearer $OLLAYA_API_KEY" --max-time 10 "$base/api/ps" || true)"
  version="$(curl -s -H "authorization: Bearer $OLLAYA_API_KEY" --max-time 10 "$base/api/version" |
    sed -n 's/.*"version":"\([^"]*\)".*/\1/p' || true)"
  http_provenance+="--- host: $host"$'\n'
  if [[ -n "$version" ]]; then
    http_provenance+="version: $version"$'\n'
    if [[ -z "${S1_OLLAYA_VERSION:-}" ]]; then
      S1_OLLAYA_VERSION="$version"
    fi
  else
    http_provenance+="version: not reported"$'\n'
  fi
  for other in ${SPECS//,/ }; do
    other_model="$(model_id "$other")"
    [[ "$(route_target "$other_model")" == "$host" ]] || continue
    tag_entry="$(printf '%s' "$tags" | tr '{' '\n' | grep -F "\"name\":\"$other_model\"" | head -1 || true)"
    ps_entry="$(printf '%s' "$ps_json" | tr '{' '\n' | grep -F "\"name\":\"$other_model\"" | head -1 || true)"
    digest="$(printf '%s' "$tag_entry" | sed -n 's/.*"digest":"\([^"]*\)".*/\1/p' || true)"
    digest="${digest:-$(printf '%s' "$ps_entry" | sed -n 's/.*"digest":"\([^"]*\)".*/\1/p' || true)}"
    vram="$(printf '%s' "$ps_entry" | sed -n 's/.*"size_vram":\([0-9][0-9]*\).*/\1/p' || true)"
    http_provenance+="model: $other_model"$'\n'
    http_provenance+="  digest: ${digest:-not reported}"$'\n'
    http_provenance+="  size_vram: ${vram:-absent (not loaded at capture time)}"$'\n'
  done
done
unset host_done
export S1_OLLAYA_VERSION

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
    echo "OLLAYA_SSH not set: version and digests captured over HTTP (RFC S1-24 Q7)"
  fi
  printf '%s' "$http_provenance"
} | tee "$OUT/environment.txt"

if [[ -n "$OLLAYA_SSH" ]]; then
  S1_OLLAYA_VERSION="$(ssh "$OLLAYA_SSH" ollaya --version 2>&1 | head -1)"
  export S1_OLLAYA_VERSION
  export S1_OLLAYA_UNLOAD_CMD="ssh $OLLAYA_SSH ollaya stop {model}"
else
  # No SSH: unload over the wire, on each model's own host (ollama-compatible
  # keep_alive=0). The runner substitutes {model}; a failed unload is a
  # warning, never fatal.
  unload_cmd='case "{model}" in'
  for spec in ${SPECS//,/ }; do
    model="$(model_id "$spec")"
    base="$(route_base "$model")"
    unload_cmd+=" ${model}) b='${base}' ;;"
  done
  unload_cmd+=' *) b= ;; esac'
  unload_cmd+='; [ -n "$b" ] && curl -s -X POST'
  unload_cmd+=' -H "authorization: Bearer ${OLLAYA_API_KEY:-local}"'
  unload_cmd+=' -H "content-type: application/json"'
  unload_cmd+=' -d '\''{"model":"{model}","keep_alive":0}'\'''
  unload_cmd+=' "$b/api/decide" >/dev/null'
  export S1_OLLAYA_UNLOAD_CMD="$unload_cmd"
fi

echo "== GPU smoke test: warm latency of a one-question request"
smoke_fail=0
for spec in ${SPECS//,/ }; do
  model="$(model_id "$spec")"
  base="$(route_base "$model")"
  # shellcheck disable=SC2016 # the backticks are part of the question text
  body=$(printf '{"model":"%s","state":{"notes":"Recheck booked in 14 days."},"questions":{"q":{"type":"noul","instructions":"Do `notes` record a follow-up plan?"}}}' "$model")
  # First call loads the model; it is timed but not judged.
  code=$(curl -s -o "$OUT/smoke-$spec.json" -w '%{http_code} %{time_total}' \
    -H "authorization: Bearer $OLLAYA_API_KEY" -H 'content-type: application/json' \
    --max-time 180 -d "$body" "$base/v1/systemone" || echo "000 0")
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
      --max-time 60 -d "$body" "$base/v1/systemone")
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
