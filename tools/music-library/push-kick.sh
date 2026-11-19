#!/bin/zsh
# push-kick.sh: the laptop's half of the nightly push (launchd com.iantodd.glancebar-music-push,
# 19:40Z through utc-daily). The push itself runs on the masters Mac over ssh (a LaunchAgent there
# cannot read the external drives: ledger W17).
#  Runs tools/music-library/push.sh there.
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
say "kick start"
ssh "${ssh_opts[@]}" "$peer" /bin/zsh "$remote_script" >> "$log" 2>&1
rc=$?
say "kick end: push exit $rc"
exit $rc
