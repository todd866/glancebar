#!/bin/zsh
# Run from a normal local Terminal: the agent sandbox cannot access account state,
# macOS file coordination, signing identities, or /Applications for installation.
set -euo pipefail
cd "${0:A:h:h}"
./build.sh

CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/glancebar-install.XXXXXX")
cleanup() {
    if (( $? == 0 )); then
        rm -rf "$CHECK_DIR"
    else
        print -u2 "Verification output retained: $CHECK_DIR/usage.json"
    fi
}
trap cleanup EXIT
build/Glancebar.app/Contents/MacOS/Glancebar --dump --online --json > "$CHECK_DIR/usage.json"
python3 - "$CHECK_DIR/usage.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
provider = next((p for p in data['ai']['providers'] if p['name'] == 'Codex'), {})
if (not provider.get('limitStatusAvailable') or provider.get('limitStale')
        or provider.get('remainingPercent') is None
        or provider.get('statusSource') not in {
            'Codex app-server account/rateLimits/read', '~/.codex session logs'}
        or provider.get('limitRefreshError')):
    details = {key: provider.get(key) for key in (
        'limitStatusAvailable', 'limitStale', 'remainingPercent', 'statusSource',
        'limitUpdatedAt', 'limitRefreshError', 'statusReason')}
    sys.exit('Codex verification failed; installed app unchanged.\n'
             + json.dumps(details, indent=2))
print(f"Fresh Codex allowance verified: {provider['remainingPercent']:.0f}% remaining "
      f"({provider['statusSource']}).")
PY

APP=/Applications/Glancebar.app
BACKUP="build/Glancebar-before-ai-sync-$(date +%Y%m%d-%H%M%S).app"
HAD_APP=0
if [[ -d "$APP" ]]; then
    ditto "$APP" "$BACKUP"
    HAD_APP=1
fi
# Quit gracefully so the old reader flushes its state before replacement.
if pgrep -x Glancebar >/dev/null; then
    osascript -e 'tell application id "com.iantodd.glancebar" to quit'
    for attempt in {1..20}; do
        if ! pgrep -x Glancebar >/dev/null; then break; fi
        sleep 0.5
    done
    if pgrep -x Glancebar >/dev/null; then
        print -u2 'Glancebar did not quit; installation stopped.'
        exit 1
    fi
fi
if ! ditto build/Glancebar.app "$APP" || ! codesign --verify --strict "$APP"; then
    print -u2 'Install failed; restoring the previous app.'
    if (( HAD_APP )); then
        ditto "$BACKUP" "$APP"
        open -g "$APP"
    fi
    exit 1
fi
open -g "$APP"
print 'Glancebar installed and restarted. Codex usage now refreshes every five minutes.'
