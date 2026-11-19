#!/bin/zsh
# zsh, not bash: on the masters Mac only zsh and python3 hold the privacy grant for external drives;
# under bash a launchd run blocks for ever inside open() on an unanswered prompt (ledger W17).
#
# Nightly on the Mac that holds the masters: copy new lossless masters from every readable root to
# the bucket, then rebuild catalogue.json from the bucket's own listing.
# Idempotent; never deletes anything on either side. See docs/music.md and docs/music-unify.md.
#
# Roots come from `masters_roots` in ~/.config/glancebar/music-library.json; a Mac without them
# exits 0. Since 19 Nov 2026 an unreadable root is a warning, not a failed push: the bucket is the
# catalogue's truth, and the previous catalogue supplies what the drive cannot.
set -u
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
here=${0:A:h}
tool="$here/musiclib.py"
state="$HOME/.local/state/glancebar-music-library"
mkdir -p "$state"
log="$state/push.log"
hist="$state/push-history.jsonl"
stamp() { date "+%Y-%m-%d %H:%M:%S"; }
say() { print -r -- "$(stamp) $*" >> "$log"; }
json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
fail() {
  say "FAIL $*"
  local e=$(json_str "$*")
  printf '{"ok":false,"at":"%s","epoch":%s,"error":%s}\n' "$(stamp)" "$(date +%s)" "$e" > "$state/push-status.json"
  printf '{"at":"%s","epoch":%s,"uploaded":0,"ok":false,"error":%s}\n' "$(stamp)" "$(date +%s)" "$e" >> "$hist"
  exit 1
}

roots=("${(@f)$(python3 "$tool" roots 2>/dev/null)}")
roots=(${roots:#})
(( ${#roots} )) || { echo "glancebar-music-push: no masters_roots in the config on this Mac; nothing to do" >&2; exit 0; }
remote=$(python3 -c 'import json,os; print(json.load(open(os.path.expanduser("~/.config/glancebar/music-library.json")))["remote"].rstrip("/"))') \
  || fail "no remote in the config"
[ -e "$HOME/.local/state/METERED_LINK" ] && fail "metered link: not uploading"
say "push start: ${#roots} roots"

# Which roots can this process read now? One bounded probe each, under disk-slot so a busy disk is
# not mistaken for a missing grant. An unreadable root is skipped, not fatal.
readable=() warnings=()
for r in $roots; do
  if [ ! -d "$r" ]; then warnings+=("not mounted: $r"); continue; fi
  ok=0
  for attempt in 1 2 3; do
    err=$(disk-slot "$r" -- gtimeout 60 ls "$r" 2>&1 >/dev/null) && { ok=1; break; }
    say "probe $attempt failed on $r: $(print -r -- "$err" | tail -1 | cut -c1-160)"
    command sleep 5
  done
  (( ok )) && readable+=("$r") || warnings+=("unreadable: $r")
done

copied_before=$(grep -c "Copied (new)" "$log" 2>/dev/null || echo 0)
# House rule (10 Nov 2026): one heavy job per physical disk; everything that reads a masters
# drive runs under disk-slot.
for r in $readable; do
  disk-slot "$r" -- rclone copy "$r" "$remote" --include "*.m4a" --include "AM-MV/**.mp4" --checksum --transfers 4 \
      --log-file "$log" --log-level INFO || warnings+=("rclone copy exited $? for $r")
done
copied_after=$(grep -c "Copied (new)" "$log" 2>/dev/null || echo 0)
uploaded=$((copied_after - copied_before))

out="$state/catalogue-last.json"
if (( ${#readable} )); then
  margs=(); for r in $readable; do margs+=(--masters "$r"); done
  disk-slot $readable -- python3 "$tool" catalogue --from-remote $margs > "$out" 2>> "$log" || fail "catalogue exited $?"
else
  python3 "$tool" catalogue --from-remote --no-archive > "$out" 2>> "$log" || fail "catalogue exited $? (no readable root)"
fi
cat "$out" >> "$log"

remote_n=$(rclone lsf -R --files-only --fast-list --include "*.m4a" "$remote/AM-Lossless" | wc -l | tr -d ' ')
python3 - "$out" "$state/push-status.json" "$hist" "$uploaded" "$remote_n" "$(stamp)" "$(date +%s)" "${(j:; :)warnings}" <<'EOF'
import json, os, sys
out, status, hist, uploaded, remote_n, at, epoch, warn = sys.argv[1:9]
rep = json.load(open(out)).get("report") or {}
doc = {"ok": True, "at": at, "epoch": int(epoch), "masters": rep.get("entries"), "remote": int(remote_n),
       "uploaded": int(uploaded), "catalogue": rep.get("entries"), "fromDrive": rep.get("drive"),
       "carried": rep.get("carried"), "fetched": rep.get("fetched"), "pending": rep.get("pending")}
warnings = [w for w in warn.split("; ") if w] + [f"unreadable: {r}" for r in rep.get("unreadableRoots") or []]
if rep.get("pending"):
    warnings.append(f"{rep['pending']} objects in the bucket not yet catalogued (fetch cap or metered)")
if warnings:
    doc["warning"] = "; ".join(dict.fromkeys(warnings))
tmp = status + ".part"
open(tmp, "w").write(json.dumps(doc) + "\n")
os.replace(tmp, status)
open(hist, "a").write(json.dumps(doc) + "\n")
EOF
say "push ok: uploaded $uploaded, ${remote_n} .m4a in the bucket; warnings: ${(j:; :)warnings:-none}"
