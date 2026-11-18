#!/bin/zsh
# nightly-kick.sh: the M5's half of the nightly map refresh (launchd com.iantodd.glancebar-music-embed,
# 20:45Z through utc-daily, after the 19:40Z push has written the catalogue).
#  1. Counts songs downloaded here (hot set, pending Apple Music pulls) that the bucket's
#     catalogue lacks, and hands that to the M2 for the gap report.
#  2. Runs tools/music-embed/nightly.sh on the M2 over ssh (the M2 has no key into the M5, and a
#     LaunchAgent on the M2 cannot read the masters drive: ledger W17; same shape as the push).
#  3. Pulls the vectors and gaps.json back into ~/.local/state/glancebar-music-embed/ here, where
#     the web radio's builder and the morning check read them, and, when the vectors changed,
#     rewrites Glancebar's mix/music-space.json with `embed.py export`.
set -u
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
peer=${MUSIC_EMBED_HOST:-m2}
remote_script=${MUSIC_EMBED_REMOTE_SCRIPT:-Projects/glancebar/tools/music-embed/nightly.sh}  # relative to the M2's home
here="${0:A:h}"
state="$HOME/.local/state/glancebar-music-embed"
remote_state=".local/state/glancebar-music-embed"
log="$state/kick.log"
mkdir -p "$state/vectors"
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { print -r -- "$(stamp) $*" >> "$log"; }
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=10)
tmp=$(mktemp -d -t music-embed-kick) || exit 1
trap 'rm -rf "$tmp"' EXIT   # a mktemp folder in the temp dir
problems=0

say "kick start"
# 1. Downloaded here but not in the bucket.
if scp -q "${ssh_opts[@]}" "$peer:.local/state/glancebar-music-library/catalogue.json" "$tmp/catalogue.json" \
   && python3 "$here/embed.py" --catalogue "$tmp/catalogue.json" local-gap --out "$tmp/local-gap.json" >> "$log" 2>&1 \
   && ssh "${ssh_opts[@]}" "$peer" "mkdir -p $remote_state/incremental" \
   && scp -q "${ssh_opts[@]}" "$tmp/local-gap.json" "$peer:$remote_state/incremental/local-gap.json"; then
  :
else
  say "local gap not counted (downloadedNotInR2 will be null)"
fi

# 2. The M2 run. Its exit code is kept; the copy-back still happens.
ssh "${ssh_opts[@]}" "$peer" /bin/zsh "$remote_script" >> "$log" 2>&1
rc=$?
say "M2 nightly exit $rc"
(( rc == 0 )) || problems=1

# 3. Vectors and the report back to this Mac. rsync writes to a temp name and renames.
before=$(cksum < "$state/vectors/tracks-index.jsonl" 2>/dev/null)
vec_ok=0
inc="$state/vectors/incoming"   # both files land here first, are checked, then move in together
mkdir -p "$inc"
if rsync -t -e "ssh ${ssh_opts[*]}" "$peer:$remote_state/vectors/tracks.f32" "$peer:$remote_state/vectors/tracks-index.jsonl" \
     "$inc/" >> "$log" 2>&1; then
  rows=$(( $(stat -f %z "$inc/tracks.f32") / 12288 ))
  lines=$(grep -c . "$inc/tracks-index.jsonl")
  if [ "$rows" = "$lines" ] && (( rows > 0 )); then
    cp -p "$inc/tracks.f32" "$state/vectors/tracks.f32.part" && cp -p "$inc/tracks-index.jsonl" "$state/vectors/tracks-index.jsonl.part" \
      && mv -f "$state/vectors/tracks.f32.part" "$state/vectors/tracks.f32" \
      && mv -f "$state/vectors/tracks-index.jsonl.part" "$state/vectors/tracks-index.jsonl" && vec_ok=1
    (( vec_ok )) || { say "FAIL could not move the vectors into place"; problems=1; }
  else
    say "FAIL copied vectors disagree: $rows rows, $lines index lines"; problems=1
  fi
else
  say "FAIL could not copy the vectors back"; problems=1
fi
rsync -t -e "ssh ${ssh_opts[*]}" "$peer:$remote_state/gaps.json" "$peer:$remote_state/nightly-status.json" "$state/" >> "$log" 2>&1 \
  || { say "FAIL could not copy gaps.json"; problems=1; }
after=$(cksum < "$state/vectors/tracks-index.jsonl" 2>/dev/null)

library="$HOME/Library/Application Support/Glancebar/mix/library.json"
if [ "$before" != "$after" ] && (( vec_ok )) && [ -f "$library" ]; then
  HEAVY_SLOT_LOCAL=1 heavy-slot -- python3 "$here/embed.py" export --vectors "$state/vectors" >> "$log" 2>&1 \
    && say "music-space.json rewritten" || { say "FAIL export"; problems=1; }
fi
say "kick end: problems=$problems"
exit $problems
