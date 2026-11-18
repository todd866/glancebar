#!/bin/zsh
# Nightly map refresh, on the M2 (started from the M5 by nightly-kick.sh, after the 19:40Z push).
# Embeds catalogue songs that are in R2 but have no vector, through the Batch API, within the
# daily spend cap, and appends them to vectors/tracks.f32 + tracks-index.jsonl. Then writes the
# gap report and copies it to the bucket as radio/gaps.json. Idempotent: every stage resumes.
# zsh, not bash: on the M2 only zsh and python3 hold the privacy grant for external drives (W17).
# State and logs: ~/.local/state/glancebar-music-embed/. See tools/music-embed/README.md.
set -u
export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
state="$HOME/.local/state/glancebar-music-embed"
tool="${0:A:h}/embed.py"
py="$state/venv/bin/python"
keyfile="$HOME/.config/glancebar/gemini.env"
log="$state/nightly.log"
mkdir -p "$state"
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { print -r -- "$(stamp) $*" >> "$log"; }
steps=() failed=()
run() {  # run NAME CMD...: log its output, remember a failure, carry on
  local name=$1; shift
  say "$name: start"
  "$@" >> "$log" 2>&1
  local rc=$?
  steps+=("$name:$rc")
  (( rc == 0 )) || failed+=("$name exit $rc")
  say "$name: exit $rc"
}
status() {  # status OK NOTE
  local ok=$1 note=$2 at=$(stamp)
  "$py" - "$state/nightly-status.json" "$ok" "$at" "$note" "${(j:,:)steps}" <<'EOF'
import json, sys, os
path, ok, at, note, steps = sys.argv[1:6]
doc = {"ok": ok == "true", "at": at, "note": note, "steps": [s for s in steps.split(",") if s]}
tmp = path + ".part"
open(tmp, "w").write(json.dumps(doc, indent=2) + "\n")
os.replace(tmp, path)
EOF
}

say "nightly start"
[ -x "$py" ] || { say "FAIL no venv at $py"; exit 1; }
[ -f "$tool" ] || { say "FAIL embed.py missing: $tool"; exit 1; }

metered=0
[ -e "$HOME/.local/state/METERED_LINK" ] && metered=1
if (( metered )); then
  say "metered link: no fetching or embedding tonight"
  failed+=("metered link")
else
  # The key is read here and given only to the child processes; never printed or logged.
  if [ -r "$keyfile" ]; then
    GEMINI_API_KEY=$(sed -n 's/^GEMINI_API_KEY=//p' "$keyfile" | head -1 | tr -d '"'"'"' \r')
    export GEMINI_API_KEY
  fi
  if [ -z "${GEMINI_API_KEY:-}" ]; then
    say "FAIL no GEMINI_API_KEY in $keyfile"
    failed+=("no key")
  else
    run collect "$py" -W ignore "$tool" increment collect
    run prepare env HEAVY_SLOT_LOCAL=1 heavy-slot -- "$py" -W ignore "$tool" increment prepare
    run submit "$py" -W ignore "$tool" increment submit
    run wait "$py" -W ignore "$tool" increment wait --timeout 7200 --interval 60
  fi
fi
run spend "$py" "$tool" spend
if (( ${#failed} )); then status false "${(j:; :)failed}"; else status true ok; fi
run gaps "$py" "$tool" gaps --upload
(( ${#failed} )) && status false "${(j:; :)failed}"
say "nightly end: ${#failed} problems"
(( ${#failed} == 0 ))
