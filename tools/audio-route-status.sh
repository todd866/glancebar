#!/bin/zsh
# Build (cached) and run tools/audio-route-status.m: Core Audio's view of per-app routing.
set -euo pipefail
HERE="${0:A:h}"
# Cache in a user-owned 0700 directory, never a shared /tmp (binary planting).
DIR="${XDG_CACHE_HOME:-$HOME/Library/Caches}/glancebar"
mkdir -p -m 700 "$DIR"
[[ -O "$DIR" ]] || { echo "refusing: $DIR is not owned by you" >&2; exit 1; }
chmod 700 "$DIR"
OUT="$DIR/audio-route-status"
# Rebuild if missing, stale, not ours, or group/world-writable (clang -o replaces it).
if [[ ! -x "$OUT" || ! -O "$OUT" || -n "$(find "$OUT" \( -perm -g+w -o -perm -o+w \) 2>/dev/null)" || "$HERE/audio-route-status.m" -nt "$OUT" ]]; then
    xcrun clang -fobjc-arc -Wall -Werror -mmacosx-version-min=13.0 "$HERE/audio-route-status.m" \
        -framework Foundation -framework CoreAudio -o "$OUT"
fi
exec "$OUT" "$@"
