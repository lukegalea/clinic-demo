#!/usr/bin/env bash
#
# Fail when the generated half of AGENTS.md (between the usage-rules markers)
# is not what `mix usage_rules.sync` would write from the current mix.exs
# config and the locked deps. Wired into `mix precommit` and CI.
#
# Catches the two ways the file drifts: a config change that was never synced
# (the ash_a2ui entry sat in mix.exs for weeks with no AGENTS.md section), and
# a dependency bump whose usage rules gained or lost sub-rules without a
# resync. The fix is always the same:
#
#   mix usage_rules.sync --yes
#
# then commit AGENTS.md with the change that caused it.
#
# This uses the sync task's own --check flag (an Igniter global): it computes
# the sync, prints the diff it would make, writes nothing, and exits non-zero
# when there is one. usage_rules and ash_agent_tools are `only: :dev`
# dependencies, so the check runs under MIX_ENV=dev even when `mix precommit`
# (MIX_ENV=test) calls it.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if MIX_ENV=dev mix usage_rules.sync --check; then
  echo "usage-rules: AGENTS.md matches the usage_rules config"
else
  echo "usage-rules: AGENTS.md is out of date; run \`mix usage_rules.sync --yes\` and commit it" >&2
  exit 1
fi
