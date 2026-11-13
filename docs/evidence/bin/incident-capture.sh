#!/usr/bin/env bash
# CLIN-33: capture the planted-incident transcripts in docs/evidence/transcripts/.
#
#   MIX_ENV=test MIX_TEST_PARTITION=incident docs/evidence/bin/incident-capture.sh
#
# Writes to the database the environment points at (a veterinarian and a patient
# per run, plus the appointment on the healthy run), so point it at a scratch
# one — the partition above is exactly that. Needs jq and a running Postgres.
# MIX_ENV=dev works too (ash_agent_tools is a dev and test dependency).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
out=docs/evidence/transcripts
export MIX_ENV="${MIX_ENV:-dev}"

# Compile and set up first: Mix's compile notice would otherwise lead the
# task's stdout, which is meant to be pure JSON.
mix compile > /dev/null
mix ash.setup --quiet > /dev/null

failing="$out/incident-book-failing.json"
CLINIC_INCIDENT=triage_vet_only mix clinic.incident book 2> /dev/null | jq -c . > "$failing"

{
  echo '$ jq "del(.spans) + {span_count: (.spans | length)}" incident-book-failing.json'
  jq 'del(.spans) + {span_count: (.spans | length)}' "$failing"
} > "$out/incident-1-book-failing.txt"

{
  echo '$ bin/ash-agent trace < incident-book-failing.json | jq .'
  bin/ash-agent trace < "$failing" 2> /dev/null | jq .
} > "$out/incident-2-trace-explain.txt"

{
  echo '$ bin/ash-agent forbidden ClinicDemo.Scheduling.Appointment record_triage | jq .'
  bin/ash-agent forbidden ClinicDemo.Scheduling.Appointment record_triage 2> /dev/null | jq .
} > "$out/incident-3-explain-forbidden.txt"

fixed="$(mktemp)"
trap 'rm -f "$fixed"' EXIT
env -u CLINIC_INCIDENT mix clinic.incident book 2> /dev/null | jq -c . > "$fixed"
{
  echo '$ mix clinic.incident book > fixed.json    # the switch off: the documented fix'
  echo '$ jq "del(.spans) + {span_count: (.spans | length)}" fixed.json'
  jq 'del(.spans) + {span_count: (.spans | length)}' "$fixed"
  echo '$ bin/ash-agent trace < fixed.json | jq "{errors, policy, summary}"'
  bin/ash-agent trace < "$fixed" 2> /dev/null | jq '{errors, policy, summary}'
} > "$out/incident-4-book-fixed.txt"

echo "wrote $out/incident-*"
