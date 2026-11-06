#!/bin/zsh
# Build Glancebar on a worker Mac, sign it here.
# The compile and the test suite are the heavy part and need only the repo, so they run on a
# remote-run worker (ad-hoc signed there). Signing needs this Mac's keychain identity and takes
# about a second, so the app is pulled back and re-signed here with exactly build.sh's identity,
# entitlements and hardened runtime. Same result as ./build.sh, without the local CPU.
# Usage: tools/build-remote.sh [remote-run options, e.g. --host m1]   ->  build/Glancebar.app
set -euo pipefail
cd "${0:A:h}/.."

remote-run "$@" --pull build/Glancebar.app -- \
    zsh -c 'GLANCEBAR_ADHOC=1 ./build.sh'

APP=build/Glancebar.app
[[ -d "$APP" ]] || { echo "build-remote: no $APP came back" >&2; exit 1; }

# Identity: the same resolution as build.sh (explicit, Developer ID, self-signed SHA-1).
SELF_SIGNED_SHA1="${GLANCEBAR_CODESIGN_SHA1:-A14E62A164EEEC5A633BFF74C2CA5409A1C4F9E7}"
IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
if [[ -n "${GLANCEBAR_CODESIGN_IDENTITY:-}" ]]; then IDENTITY="$GLANCEBAR_CODESIGN_IDENTITY"
elif DEV=$(print -r -- "$IDS" | grep -m1 "Developer ID Application" | sed -E 's/^[^"]*"([^"]+)".*/\1/') && [[ -n "$DEV" ]]; then IDENTITY="$DEV"
elif print -r -- "$IDS" | grep -qi "$SELF_SIGNED_SHA1"; then IDENTITY="$SELF_SIGNED_SHA1"
else echo "build-remote: no signing identity on this Mac; use ./build.sh" >&2; exit 1; fi

ARGS=(--force --sign "$IDENTITY" --entitlements Glancebar.entitlements)
[[ "${GLANCEBAR_HARDENED_RUNTIME:-1}" == "1" ]] && ARGS+=(--options runtime)
[[ "${GLANCEBAR_TIMESTAMP:-0}" == "1" ]] && ARGS+=(--timestamp)
for ATTRIBUTE in com.apple.FinderInfo com.apple.ResourceFork; do xattr -dr "$ATTRIBUTE" "$APP" 2>/dev/null || true; done
echo "Signing identity: $IDENTITY"
codesign "${ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built remotely, signed here: $APP"
