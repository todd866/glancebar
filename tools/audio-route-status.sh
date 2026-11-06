#!/bin/zsh
# Build (cached) and run tools/audio-route-status.m: Core Audio's view of per-app routing.
set -euo pipefail
HERE="${0:A:h}"
OUT="${TMPDIR:-/tmp}/glancebar-audio-route-status"
if [[ ! -x "$OUT" || "$HERE/audio-route-status.m" -nt "$OUT" ]]; then
    xcrun clang -fobjc-arc -Wall -Werror -mmacosx-version-min=13.0 "$HERE/audio-route-status.m" \
        -framework Foundation -framework CoreAudio -o "$OUT"
fi
exec "$OUT" "$@"
