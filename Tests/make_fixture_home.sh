#!/bin/zsh
# Builds a throwaway GLANCEBAR_HOME whose AI state is fully determined, so a --dump
# contract check sees real provider windows instead of the empty-home degenerate case.
# Timestamps are stamped at generation time: every window must still be current when the
# dump runs, or the very reset-elapsed paths we are trying to exercise take over.
#
# Usage: Tests/make_fixture_home.sh <dir>
set -euo pipefail
DIR="${1:?usage: make_fixture_home.sh <dir>}"
NOW=$(date +%s)
FIVE_HOUR=$((NOW + 3600))        # Codex plan 5-hour window, still open
WEEKLY=$((NOW + 4 * 86400))      # Codex plan weekly, spent but not yet reset
SIDE_WEEKLY=$((NOW + 6 * 86400)) # an untouched side bucket, newer than the plan snapshot
CLAUDE_FIVE=$((NOW + 7200))
CLAUDE_WEEK=$((NOW + 3 * 86400))

rm -rf "$DIR"
mkdir -p "$DIR/.codex/sessions/2026/09/07" "$DIR/Library/Application Support/Glancebar"

ts() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
USAGE='"info":{"last_token_usage":{"total_tokens":1200,"input_tokens":1000,"cached_input_tokens":200,"output_tokens":100}}'
CREDITS='"credits":{"has_credits":false,"unlimited":false,"balance":"0"}'
ROLLOUT="$DIR/.codex/sessions/2026/09/07/rollout-fixture.jsonl"
{
  # The plan allowance, 99% spent, weekly window in the PRIMARY slot with no secondary.
  print -r -- "{\"timestamp\":\"$(ts $((NOW - 600)))\",\"payload\":{\"type\":\"token_count\",$USAGE,\"rate_limits\":{\"limit_id\":\"codex\",\"plan_type\":\"pro\",\"primary\":{\"used_percent\":99.0,\"window_minutes\":10080,\"resets_at\":$WEEKLY},\"secondary\":null,$CREDITS}}}"
  # A side bucket reporting later and reporting room. It must not become the gauge.
  print -r -- "{\"timestamp\":\"$(ts $((NOW - 300)))\",\"payload\":{\"type\":\"token_count\",$USAGE,\"rate_limits\":{\"limit_id\":\"codex_fixture\",\"plan_type\":\"pro\",\"primary\":{\"used_percent\":0.0,\"window_minutes\":300,\"resets_at\":$FIVE_HOUR},\"secondary\":{\"used_percent\":0.0,\"window_minutes\":10080,\"resets_at\":$SIDE_WEEKLY},$CREDITS}}}"
  # Billing moved to credits: both windows null, no credits left.
  print -r -- "{\"timestamp\":\"$(ts $((NOW - 60)))\",\"payload\":{\"type\":\"token_count\",$USAGE,\"rate_limits\":{\"limit_id\":\"premium\",\"plan_type\":\"pro\",\"primary\":null,\"secondary\":null,$CREDITS}}}"
} > "$ROLLOUT"

# A last-known Claude account response in the 2026-09 limits[] shape, so the Claude
# provider has windows without any network access or Keychain read.
cat > "$DIR/Library/Application Support/Glancebar/ai-reader-state-v2.json" <<JSON
{
  "version": 2,
  "timeZone": "$(/usr/bin/plutil -extract 0 raw -o - /dev/stdin <<<'["placeholder"]' >/dev/null 2>&1; date +%Z)",
  "codexFiles": {},
  "claudeFiles": {},
  "claudeUsageFetchedAt": "$(ts $((NOW - 120)))",
  "claudeUsageJSON": {
    "limits": [
      {"kind": "session", "group": "session", "is_active": true, "percent": 25, "resets_at": $CLAUDE_FIVE, "scope": null},
      {"kind": "weekly_all", "group": "weekly", "is_active": false, "percent": 60, "resets_at": $CLAUDE_WEEK, "scope": null},
      {"kind": "weekly_scoped", "group": "weekly", "is_active": false, "percent": 75, "resets_at": $CLAUDE_WEEK,
       "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
    ],
    "extra_usage": {"is_enabled": false, "disabled_reason": "out_of_credits", "monthly_limit": 20000, "currency": "AUD"}
  }
}
JSON
# The timeZone key must match the machine that reads it, or the index is treated as
# foreign. Rewrite it with the IANA name Foundation itself would use.
/usr/bin/python3 - "$DIR/Library/Application Support/Glancebar/ai-reader-state-v2.json" <<'PY'
import json, sys, subprocess
path = sys.argv[1]
zone = subprocess.run(['/bin/sh', '-c', 'readlink /etc/localtime | sed "s|.*/zoneinfo/||"'],
                      capture_output=True, text=True).stdout.strip()
with open(path) as fh:
    doc = json.load(fh)
doc['timeZone'] = zone
with open(path, 'w') as fh:
    json.dump(doc, fh, indent=2)
PY
echo "$DIR"
