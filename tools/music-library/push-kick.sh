#!/bin/zsh
# push-kick.sh: the laptop's half of the nightly push (launchd com.iantodd.glancebar-music-push,
# 19:40Z through utc-daily). The push itself runs on the masters Mac over ssh (a LaunchAgent there
# cannot read the external drives: ledger W17).
#  1. Writes the alias claims only this Mac has (Apple song ids from the scout ledger and the
#     favourites pull, persistent ids from Glancebar's library copy) and copies them into the
#     masters Mac's alias-inputs/, where the catalogue builder (the only writer of music/ids.json)
#     reads them. A failure here only leaves last night's claims in place.
#  2. Runs tools/music-library/push.sh there.
set -u
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
peer=${MUSIC_PUSH_HOST:-m2}
remote_script=${MUSIC_PUSH_REMOTE_SCRIPT:-Projects/glancebar/tools/music-library/push.sh}  # relative to the peer's home
here="${0:A:h}"
state="$HOME/.local/state/glancebar-music-library"
log="$state/push-kick.log"
mkdir -p "$state"
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { print -r -- "$(stamp) $*" >> "$log"; }
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=6)
tmp=$(mktemp -d -t music-push-kick) || exit 1
trap 'rm -rf "$tmp"' EXIT   # a mktemp folder in the temp dir
claims="$tmp/$(scutil --get LocalHostName 2>/dev/null || hostname -s).jsonl"
claims=${claims:l}
say "kick start"
if python3 "$here/../music-store/musicstore.py" claims \
     --apple-ledger "$HOME/.local/state/glancebar-music-scout/ledger.jsonl" \
     --liked-pulled "$HOME/.local/state/glancebar-mix/liked-pulled.json" \
     --library "$HOME/Library/Application Support/Glancebar/mix/library.json" \
     --out "$claims" >> "$log" 2>&1 \
   && scp -q "${ssh_opts[@]}" "$claims" "$peer:.local/state/glancebar-music-library/alias-inputs/"; then
  :
else
  say "alias claims not copied (last night's stay)"
fi
ssh "${ssh_opts[@]}" "$peer" /bin/zsh "$remote_script" >> "$log" 2>&1
rc=$?
say "kick end: push exit $rc"
exit $rc
