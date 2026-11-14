#!/bin/zsh
# Drives menubar-morning-check.sh against a fake home and stubbed tools.
# HOME is deliberately empty: the script must read MORNING_HOME / MORNING_APPS_DIR.
set -u
umask 077

SCRIPT="${0:A:h}/menubar-morning-check.sh"
VER=9.9.9
failures=0
temps=()
trap 'rm -rf "${temps[@]}"' EXIT

ok() { print "ok $1"; }
not_ok() { print "not ok $1"; failures=$((failures + 1)); }

new_case() {
  local work home apps bin trace
  work=$(mktemp -d "${TMPDIR:-/tmp}/menubar-morning-check.XXXXXX")
  temps+=("$work")
  home="$work/home"
  apps="$work/apps"
  bin="$work/bin"
  trace="$work/trace"
  mkdir -p "$bin" \
    "$home/Library/Logs/menubar-morning-check" \
    "$home/Library/Application Support/IDriveforMac/SessionLogsNew/LOGXML" \
    "$home/Library/Application Support/IDriveforMac/SessionLogsNew/Backup" \
    "$home/.config/energybar" \
    "$home/.cache/energybar" \
    "$home/.local/state/stash" \
    "$home/.config/remote-run" \
    "$home/Projects/glancebar" \
    "$home/Projects/glancebar/tools/media-sync" \
    "$home/Projects/energybar" \
    "$work/unused-home" \
    "$apps/Glancebar.app/Contents/MacOS" \
    "$apps/Energybar.app/Contents/MacOS"

  cat > "$apps/Glancebar.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>$VER</string>
</dict></plist>
EOF
  cp "$apps/Glancebar.app/Contents/Info.plist" "$apps/Energybar.app/Contents/Info.plist"
  cat > "$apps/Glancebar.app/Contents/MacOS/Glancebar" <<EOF
#!/bin/zsh
print -r -- "Glancebar \$*" >> "$trace"
[[ \$1 == --dump && \$2 == --json ]] || exit 1
print '{"ok":true}'
EOF
  cat > "$apps/Energybar.app/Contents/MacOS/Energybar" <<EOF
#!/bin/zsh
print -r -- "Energybar \$*" >> "$trace"
[[ \$1 == --dump && \$2 == --json ]] || exit 1
print '{"ok":true}'
EOF
  chmod +x "$apps/Glancebar.app/Contents/MacOS/Glancebar" "$apps/Energybar.app/Contents/MacOS/Energybar"
  touch "$apps/Glancebar.app/Contents/MacOS/Glancebar" "$apps/Energybar.app/Contents/MacOS/Energybar"

  cat > "$bin/git" <<EOF
#!/bin/zsh
print -r -- "git \$*" >> "$trace"
joined="\$*"
if [[ \$joined == *fetch* ]]; then exit 0; fi
if [[ \$joined == *'log -1'* ]]; then print '1700000000:abc1234'; exit 0; fi
if [[ \$joined == *Info.plist* ]]; then
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>$VER</string>
</dict></plist>
PLIST
  exit 0
fi
if [[ \$joined == *'worktree add'* ]]; then
  mkdir -p "\$6"
  exit 0
fi
if [[ \$joined == *'worktree remove'* ]]; then
  rm -rf "\$6"
  exit 0
fi
print -u2 "unexpected git: \$*"
exit 1
EOF

  cat > "$bin/pgrep" <<EOF
#!/bin/zsh
print -r -- "pgrep \$*" >> "$trace"
exit 0
EOF
  cat > "$bin/ssh" <<EOF
#!/bin/zsh
print -r -- "ssh \$*" >> "$trace"
print "$VER \$(date +%s)"
exit 0
EOF
  cat > "$bin/remote-run" <<EOF
#!/bin/zsh
print -r -- "remote-run \$*" >> "$trace"
code=0
[[ -f "$work/remote-exit" ]] && code=\$(<"$work/remote-exit")
if (( code == 4 )); then
  print -u2 "remote-run: no worker reachable (m2)"
fi
if (( code != 0 && code != 255 && code != 4 )); then
  print "not ok sample"
fi
exit \$code
EOF
  cat > "$bin/heavy-slot" <<EOF
#!/bin/zsh
print -r -- "heavy-slot label=\${HEAVY_SLOT_LABEL:-} \$*" >> "$trace"
exit 0
EOF
  cat > "$bin/log" <<EOF
#!/bin/zsh
print -r -- "log \$*" >> "$trace"
exit 0
EOF
  cat > "$bin/osascript" <<EOF
#!/bin/zsh
print -r -- "osascript \$*" >> "$trace"
print -r -- "\$*" >> "$work/osascript.txt"
exit 0
EOF
  chmod +x "$bin/git" "$bin/pgrep" "$bin/ssh" "$bin/remote-run" "$bin/heavy-slot" "$bin/log" "$bin/osascript"

  cat > "$home/Projects/glancebar/tools/media-sync/media_sync.py" <<'EOF'
#!/usr/bin/env python3
import sys
if "collect" in sys.argv:
    raise SystemExit(0)
if "check" in sys.argv:
    print("PASS ledger: quiet")
    raise SystemExit(0)
raise SystemExit(2)
EOF
  chmod +x "$home/Projects/glancebar/tools/media-sync/media_sync.py"

  print -r -- '# remote-run workers' > "$home/.config/remote-run/hosts"
  print -r -- 'm2' >> "$home/.config/remote-run/hosts"
  print -r -- '# m1 disabled' >> "$home/.config/remote-run/hosts"
  print -r -- '{"soc": 80.0}' > "$home/.cache/energybar/vehicle-cloud.json"
  print -r -- '2020-01-01 00:00:00 old reclaim note' > "$home/.local/state/stash/reclaim.log"
  : > "$home/.local/state/stash/reclaim.err"

  local now_stamp backup logbase
  now_stamp=$(date '+%m-%d-%Y %H:%M:%S')
  backup="$home/Library/Application Support/IDriveforMac/SessionLogsNew/Backup"
  logbase="$backup/run-new"
  : > "$logbase"
  print -r -- 'Files failed to backup: 2' > "$logbase.summary"
  : > "$backup/run-old"
  print -r -- 'Files failed to backup: 100' > "$backup/run-old.summary"
  cat > "$home/Library/Application Support/IDriveforMac/SessionLogsNew/LOGXML/session.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<records>
<record>
<status>Success</status>
<datetime>01-01-2020 00:00:00</datetime>
<logfile>$backup/run-old</logfile>
</record>
<record>
<status>Failure</status>
<datetime>$now_stamp</datetime>
<logfile>$backup/run-new</logfile>
</record>
</records>
EOF

  CASE_WORK="$work"
  CASE_HOME="$home"
  CASE_APPS="$apps"
  CASE_TRACE="$trace"
  export HOME="$work/unused-home"
  export MORNING_HOME="$home"
  export MORNING_APPS_DIR="$apps"
  export PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin"
  unset MORNING_LOG_DIR MORNING_GLANCEBAR_REPO MORNING_ENERGYBAR_REPO
}

run_script() {
  local out err rc
  out="$CASE_WORK/stdout"
  err="$CASE_WORK/stderr"
  zsh "$SCRIPT" "$@" >"$out" 2>"$err"
  rc=$?
  CASE_RC=$rc
  return 0
}

trace_has() { grep -q -- "$1" "$CASE_TRACE"; }
trace_count() { grep -c -- "$1" "$CASE_TRACE" 2>/dev/null || true; }

print "1..11"

if [[ ! -f $SCRIPT ]]; then
  not_ok "script exists"
  print "$failures failed"
  exit 1
fi

# --- all PASS, including an iDrive Failure that only lost two files ---
new_case
run_script
report() { print -r -- "$CASE_HOME/Library/Logs/menubar-morning-check"; }
if (( CASE_RC == 0 )) \
  && [[ ! -e $CASE_WORK/osascript.txt ]] \
  && grep -q '^PASS iDrive: Failure, 2 files failed' "$(report)/latest.txt" \
  && ! grep -qE '^(WARN|FAIL) ' "$(report)/latest.txt" \
  && cmp -s "$(report)/latest.txt" "$(report)/$(date '+%F').txt" \
  && (( $(trace_count '^ssh ') == 1 )) \
  && trace_has 'subsystem == "com.iantodd.glancebar"' \
  && trace_has 'worktree remove'; then
  ok "all-pass is silent and accepts iDrive Failure with 2 files"
else
  not_ok "all-pass is silent and accepts iDrive Failure with 2 files"
  print -r -- "rc=$CASE_RC"
  cat "$CASE_WORK/stderr" >&2
  cat "$(report)/latest.txt" 2>/dev/null >&2
fi
python_ok=$(/usr/bin/python3 -c '
import json, sys
line=open(sys.argv[1]).read().strip().splitlines()[-1]
row=json.loads(line)
assert row["date"] == sys.argv[2]
assert row["fail"] == 0 and row["warn"] == 0 and row["pass"] > 0
assert isinstance(row["seconds"], int) and row["seconds"] >= 0
' "$(report)/runs.jsonl" "$(date '+%F')" && print yes || print no)
if [[ $python_ok == yes ]]; then
  ok "runs.jsonl records a clean run"
else
  not_ok "runs.jsonl records a clean run"
  cat "$(report)/runs.jsonl" 2>/dev/null >&2
fi

# --- failing suite notifies once ---
new_case
print -r -- 1 > "$CASE_WORK/remote-exit"
run_script
note="$CASE_WORK/osascript.txt"
if grep -q '^FAIL Glancebar tests: not ok sample' "$(report)/latest.txt" \
  && grep -q '^FAIL Energybar tests: not ok sample' "$(report)/latest.txt" \
  && [[ -f $note ]] && (( $(wc -l < "$note") == 1 )) \
  && grep -F -q '2 FAIL, 0 WARN — see latest.txt' "$note" \
  && grep -F -q 'Morning check' "$note"; then
  ok "failing suite yields FAIL and one notification"
else
  not_ok "failing suite yields FAIL and one notification"
  cat "$note" 2>/dev/null >&2
  cat "$CASE_HOME/Library/Logs/menubar-morning-check/latest.txt" 2>/dev/null >&2
fi

# --- skip-dates runs nothing ---
new_case
print -r -- "$(date '+%F')" > "$CASE_HOME/Library/Logs/menubar-morning-check/skip-dates"
run_script
if (( CASE_RC == 0 )) && [[ ! -s $CASE_TRACE ]] && [[ ! -e "$(report)/latest.txt" ]]; then
  ok "skip-dates exits 0 without probes"
else
  not_ok "skip-dates exits 0 without probes"
  print -r -- "rc=$CASE_RC"
  cat "$CASE_TRACE" 2>/dev/null >&2
fi

# --- --check runs nothing ---
new_case
run_script --check
if (( CASE_RC == 0 )) && [[ ! -s $CASE_TRACE ]] \
  && grep -q 'Glancebar install' "$CASE_WORK/stdout" \
  && grep -q 'Glancebar tests' "$CASE_WORK/stdout" \
  && grep -q 'Energybar tests' "$CASE_WORK/stdout" \
  && grep -q 'iDrive' "$CASE_WORK/stdout" \
  && grep -q 'stash' "$CASE_WORK/stdout" \
  && grep -q 'media:' "$CASE_WORK/stdout" \
  && [[ ! -e "$(report)/latest.txt" ]]; then
  ok "--check prints probes and runs nothing"
else
  not_ok "--check prints probes and runs nothing"
  print -r -- "rc=$CASE_RC"
  cat "$CASE_WORK/stdout" >&2
  cat "$CASE_TRACE" 2>/dev/null >&2
fi

# --- --quick skips suites ---
new_case
run_script --quick
if (( CASE_RC == 0 )) && ! trace_has '^remote-run ' && ! trace_has 'worktree add' \
  && ! grep -q 'tests:' "$(report)/latest.txt"; then
  ok "--quick skips test suites"
else
  not_ok "--quick skips test suites"
  cat "$CASE_TRACE" >&2
fi

# --- remote-run 255 falls back to heavy-slot ---
new_case
print -r -- 255 > "$CASE_WORK/remote-exit"
run_script
if grep -q '^PASS Glancebar tests:' "$(report)/latest.txt" \
  && grep -q '^PASS Energybar tests:' "$(report)/latest.txt" \
  && trace_has 'heavy-slot label=morning-check -- ./tests.sh' \
  && [[ ! -e $CASE_WORK/osascript.txt ]]; then
  ok "remote-run 255 falls back to heavy-slot"
else
  not_ok "remote-run 255 falls back to heavy-slot"
  cat "$CASE_TRACE" >&2
  cat "$CASE_HOME/Library/Logs/menubar-morning-check/latest.txt" 2>/dev/null >&2
fi

# --- bad option ---
# --- the helper's own file decides: a signed-out Geely login warns, a network miss passes ---
new_case
print -r -- '{"error": "signed out", "checkedAt": "x"}' > "$CASE_HOME/.cache/energybar/vehicle-cloud.json"
run_script
if grep -q '^WARN Energybar helper: signed out' "$(report)/latest.txt"; then
  ok "helper signed-out warns"
else
  not_ok "helper signed-out warns"
  cat "$(report)/latest.txt" 2>/dev/null >&2
fi
new_case
print -r -- '{"soc": 80.0, "error": "TimeoutError"}' > "$CASE_HOME/.cache/energybar/vehicle-cloud.json"
run_script
if grep -q '^PASS Energybar helper: polled 0m ago, last try TimeoutError' "$(report)/latest.txt"; then
  ok "helper network miss passes"
else
  not_ok "helper network miss passes"
  cat "$(report)/latest.txt" 2>/dev/null >&2
fi

new_case
run_script --nope
if (( CASE_RC == 2 )) && [[ ! -s $CASE_TRACE ]]; then
  ok "unknown option exits 2"
else
  not_ok "unknown option exits 2"
  print -r -- "rc=$CASE_RC"
fi

# --- media sync stub passes check lines through ---
new_case
mkdir -p "$CASE_HOME/Projects/glancebar/tools/media-sync"
cat > "$CASE_HOME/stub-media-sync.py" <<'EOF'
#!/usr/bin/env python3
import sys
if "collect" in sys.argv:
    raise SystemExit(0)
print("PASS ledger: 1 tracks, 1 likes, 0 shazams")
print("WARN shazam: 1 waiting, oldest 4 d")
EOF
chmod +x "$CASE_HOME/stub-media-sync.py"
export MORNING_MEDIA_SYNC="$CASE_HOME/stub-media-sync.py"
export MORNING_GLANCEBAR_REPO="$CASE_HOME/Projects/glancebar"
run_script
if grep -q '^PASS media ledger:' "$(report)/latest.txt" \
  && grep -q '^WARN media shazam:' "$(report)/latest.txt"; then
  ok "media probe records PASS and WARN lines"
else
  not_ok "media probe records PASS and WARN lines"
  cat "$(report)/latest.txt" 2>/dev/null >&2
fi
unset MORNING_MEDIA_SYNC

if (( failures > 0 )); then
  print "$failures failed"
  exit 1
fi
print "all passed"
exit 0
