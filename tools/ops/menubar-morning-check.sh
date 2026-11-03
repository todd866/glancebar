#!/bin/zsh
# Menu-bar morning check. launchd starts it; README.md installs the agent.
# Probes only: no AI tokens, no repairs.
set -u
umask 077
setopt PIPE_FAIL
zmodload zsh/datetime

: "${MORNING_HOME:=$HOME}"
: "${MORNING_APPS_DIR:=/Applications}"
: "${MORNING_LOG_DIR:=$MORNING_HOME/Library/Logs/menubar-morning-check}"
: "${MORNING_GLANCEBAR_REPO:=$MORNING_HOME/Projects/glancebar}"
: "${MORNING_ENERGYBAR_REPO:=$MORNING_HOME/Projects/energybar}"

# Keep the caller's PATH first so a test can stub tools, then add the
# locations launchd will not have on its own.
export PATH="$PATH:$MORNING_HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"

QUICK=0
CHECK=0
for arg in "$@"; do
  case $arg in
    --check) CHECK=1 ;;
    --quick) QUICK=1 ;;
    *) print -u2 "Only --check and --quick are supported"; exit 2 ;;
  esac
done

print_plan() {
  local g="$MORNING_GLANCEBAR_REPO" e="$MORNING_ENERGYBAR_REPO" a="$MORNING_APPS_DIR"
  print -r -- "Glancebar install: git -C $g fetch -q origin; compare $a/Glancebar.app mtime and CFBundleShortVersionString with origin/main"
  print -r -- "Glancebar running: pgrep -x Glancebar; $a/Glancebar.app/Contents/MacOS/Glancebar --dump --json"
  if (( ! QUICK )); then
    print -r -- "Glancebar tests: git -C $g worktree add --detach TMP origin/main; remote-run -- ./tests.sh"
  fi
  print -r -- "Glancebar errors: log show --last 24h --style compact --predicate 'subsystem == \"com.iantodd.glancebar\" AND messageType == error'"
  print -r -- "Energybar install: git -C $e fetch -q origin; compare $a/Energybar.app mtime and CFBundleShortVersionString with origin/main"
  print -r -- "Energybar running: pgrep -x Energybar; $a/Energybar.app/Contents/MacOS/Energybar --dump --json"
  if (( ! QUICK )); then
    print -r -- "Energybar tests: git -C $e worktree add --detach TMP origin/main; remote-run -- ./tests.sh"
  fi
  print -r -- "Energybar helper: $MORNING_HOME/.cache/energybar/vehicle-cloud.json"
  print -r -- "workers: ssh -o BatchMode=yes -o ConnectTimeout=8 HOST for each host in $MORNING_HOME/.config/remote-run/hosts"
  print -r -- "iDrive: newest record in $MORNING_HOME/Library/Application Support/IDriveforMac/SessionLogsNew/LOGXML"
  print -r -- "stash: tail $MORNING_HOME/.local/state/stash/reclaim.log and reclaim.err"
}

if (( CHECK )); then
  print_plan
  exit 0
fi

TODAY=$(date '+%F')
mkdir -p "$MORNING_LOG_DIR"
skip="$MORNING_LOG_DIR/skip-dates"
if [[ -f $skip ]] && grep -qx -- "$TODAY" "$skip"; then
  print "$(date '+%F %T') SKIP $TODAY" >> "$MORNING_LOG_DIR/launcher.log"
  exit 0
fi

# lockf releases if this process dies, so a crashed run cannot block the next morning.
lockfile="$MORNING_LOG_DIR/run.lock"
exec {lockfd}>"$lockfile"
if ! /usr/bin/lockf -t 0 "$lockfd"; then
  print -u2 "morning check already running"
  exit 0
fi

typeset -a REPORT
REPORT=()
PASS_N=0
WARN_N=0
FAIL_N=0
WT_PARENT=""
WT_REPO=""
RUN_STARTED=0
FINISHED=0
STARTED=$EPOCHSECONDS

# Deadline for one command. 124 when it does not finish. Stdin stays with the caller.
run_timeout() {
  local secs=$1
  shift
  /usr/bin/python3 -c '
import subprocess, sys
secs = float(sys.argv[1])
try:
    result = subprocess.run(sys.argv[2:], timeout=secs)
except subprocess.TimeoutExpired:
    sys.exit(124)
code = result.returncode
sys.exit(code if code is not None and code >= 0 else 124)
' "$secs" "$@"
}

last_fail() {
  /usr/bin/python3 -c '
import sys
lines = []
for path in sys.argv[1:]:
    try:
        lines += open(path, errors="replace").read().splitlines()
    except OSError:
        pass
lines = [line.strip() for line in lines if line.strip()]
keys = ("fail", "error", "not ok", "assert")
bad = [line for line in lines if any(key in line.lower() for key in keys)]
print((bad or lines or ["failed"])[-1][:160])
' "$@"
}

record() {
  local kind=$1 area=$2 fact=$3
  local line="$kind $area: $fact"
  REPORT+=("$line")
  case $kind in
    PASS) PASS_N=$((PASS_N + 1)) ;;
    WARN) WARN_N=$((WARN_N + 1)) ;;
    FAIL) FAIL_N=$((FAIL_N + 1)) ;;
  esac
  print -r -- "$line"
}

note_info() {
  local line="INFO $1: $2"
  REPORT+=("$line")
  print -r -- "$line"
}

cleanup_wt() {
  [[ -n $WT_PARENT ]] || return 0
  if ! git -C "$WT_REPO" worktree remove --force "$WT_PARENT/tree" >/dev/null 2>&1; then
    rm -rf "$WT_PARENT/tree"
    git -C "$WT_REPO" worktree prune >/dev/null 2>&1 || true
  fi
  rm -rf "$WT_PARENT"
  WT_PARENT=""
  WT_REPO=""
}

finish() {
  (( FINISHED )) && return 0
  FINISHED=1
  (( RUN_STARTED )) || return 0
  local seconds=$((EPOCHSECONDS - STARTED))
  local report="$MORNING_LOG_DIR/${TODAY}.txt"
  if (( ${#REPORT} )); then
    print -rl -- "${REPORT[@]}" > "$report"
  else
    : > "$report"
  fi
  cp "$report" "$MORNING_LOG_DIR/latest.txt"
  /usr/bin/python3 -c 'import json,sys; print(json.dumps({"date":sys.argv[1],"pass":int(sys.argv[2]),"warn":int(sys.argv[3]),"fail":int(sys.argv[4]),"seconds":int(sys.argv[5])},separators=(",",":")))' \
    "$TODAY" "$PASS_N" "$WARN_N" "$FAIL_N" "$seconds" >> "$MORNING_LOG_DIR/runs.jsonl"
  if (( FAIL_N > 0 || WARN_N > 0 )); then
    osascript -e "display notification \"${FAIL_N} FAIL, ${WARN_N} WARN — see latest.txt\" with title \"Morning check\""
  fi
}

on_exit() {
  cleanup_wt
  finish
}
trap on_exit EXIT INT TERM

plist_version() {
  local file=$1 out rc
  out=$(mktemp)
  run_timeout 10 /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$file" >"$out" 2>/dev/null
  rc=$?
  if (( rc == 0 )); then
    tr -d '[:space:]' < "$out"
  fi
  rm -f "$out"
  return $rc
}

repo_version() {
  local file=$1
  /usr/bin/python3 -c '
import plistlib, sys
try:
    print(plistlib.loads(open(sys.argv[1], "rb").read())["CFBundleShortVersionString"])
except Exception:
    raise SystemExit(1)
' "$file" 2>/dev/null
}

probe_install() {
  local area=$1 repo=$2 appname=$3 binaryname=$4
  local app="$MORNING_APPS_DIR/$appname"
  local bin="$app/Contents/MacOS/$binaryname"
  local plist="$app/Contents/Info.plist"
  local out err rc meta epoch sha installed repo_ver built
  if [[ ! -x $bin || ! -f $plist ]]; then
    record FAIL "$area" "app missing"
    return
  fi
  out=$(mktemp)
  err=$(mktemp)
  # Fetch is read-only. A failed fetch still compares against the origin/main we have.
  run_timeout 60 git -C "$repo" fetch -q origin >"$out" 2>"$err" || true
  run_timeout 20 git -C "$repo" log -1 --format=%ct:%h origin/main -- Sources Info.plist >"$out" 2>"$err"
  rc=$?
  meta=$(<"$out")
  meta=${meta//[[:space:]]/}
  if (( rc != 0 )) || [[ $meta != *:* ]]; then
    record WARN "$area" "origin/main unreadable"
    rm -f "$out" "$err"
    return
  fi
  epoch=${meta%%:*}
  sha=${meta#*:}
  run_timeout 20 git -C "$repo" show "$sha:Info.plist" >"$out" 2>"$err"
  rc=$?
  repo_ver=""
  if (( rc == 0 )); then
    repo_ver=$(repo_version "$out" || true)
  fi
  installed=$(plist_version "$plist" || true)
  built=$(stat -f %m "$bin")
  if [[ -z $installed || -z $repo_ver ]]; then
    record WARN "$area" "version unreadable"
  elif [[ $installed != "$repo_ver" ]]; then
    record WARN "$area" "$installed != $repo_ver"
  # Ian's flow builds, installs, then commits, so the binary is usually seconds older than its commit.
  elif [[ $built != <-> || $epoch != <-> ]] || (( built + 1800 < epoch )); then
    record WARN "$area" "$installed built before $sha"
  else
    record PASS "$area" "$installed"
  fi
  rm -f "$out" "$err"
}

probe_running() {
  local area=$1 proc=$2 bin=$3
  local out err rc
  if ! pgrep -x "$proc" >/dev/null; then
    record FAIL "$area" "not running"
    return
  fi
  out=$(mktemp)
  err=$(mktemp)
  run_timeout 60 "$bin" --dump --json >"$out" 2>"$err"
  rc=$?
  if (( rc == 124 )); then
    record FAIL "$area" "dump timed out"
  elif (( rc != 0 )); then
    record FAIL "$area" "dump exit $rc"
  elif ! /usr/bin/python3 -c 'import json,sys; json.load(sys.stdin)' <"$out" >/dev/null 2>&1; then
    record FAIL "$area" "dump not json"
  else
    record PASS "$area" "dump ok"
  fi
  rm -f "$out" "$err"
}

should_fallback() {
  local rc=$1
  # A passing suite must not be re-run because its output mentioned workers.
  (( rc == 0 )) && return 1
  if (( rc == 255 || rc == 4 || rc == 127 )); then
    return 0
  fi
  if grep -q 'no worker reachable' "$2" "$3" 2>/dev/null; then
    return 0
  fi
  return 1
}

probe_tests() {
  local area=$1 repo=$2
  local parent wt out err rc fact runner
  cleanup_wt
  parent=$(mktemp -d "${TMPDIR:-/tmp}/morning-check.XXXXXX")
  wt="$parent/tree"
  WT_PARENT=$parent
  WT_REPO=$repo
  out=$(mktemp)
  err=$(mktemp)
  # Detached worktree so the suite does not touch the working checkout.
  run_timeout 120 git -C "$repo" worktree add --detach "$wt" origin/main >"$out" 2>"$err"
  rc=$?
  if (( rc != 0 )); then
    fact=$(last_fail "$out" "$err")
    record FAIL "$area" "${fact:-worktree add failed}"
    rm -f "$out" "$err"
    cleanup_wt
    return
  fi
  run_timeout 2700 zsh -c 'cd "$1" && exec remote-run -- ./tests.sh' morning-check "$wt" >"$out" 2>"$err"
  rc=$?
  runner=remote-run
  # 255 is the documented fallback; remote-run itself exits 4 when no worker answers.
  if should_fallback "$rc" "$out" "$err"; then
    run_timeout 2700 zsh -c 'cd "$1" && exec env HEAVY_SLOT_LABEL=morning-check heavy-slot -- ./tests.sh' morning-check "$wt" >"$out" 2>"$err"
    rc=$?
    runner=heavy-slot
  fi
  if (( rc == 0 )); then
    record PASS "$area" "$runner"
  elif (( rc == 124 )); then
    record FAIL "$area" "timed out"
  else
    fact=$(last_fail "$out" "$err")
    record FAIL "$area" "${fact:-exit $rc}"
  fi
  rm -f "$out" "$err"
  cleanup_wt
}

probe_errors() {
  local out err rc parsed n msg
  out=$(mktemp)
  err=$(mktemp)
  run_timeout 90 log show --last 24h --style compact --predicate 'subsystem == "com.iantodd.glancebar" AND messageType == error' >"$out" 2>"$err"
  rc=$?
  if (( rc == 124 )); then
    record WARN "Glancebar errors" "log show timed out"
  elif (( rc != 0 )); then
    record WARN "Glancebar errors" "log show exit $rc"
  else
    parsed=$(/usr/bin/python3 -c '
import collections, re, sys
lines = [line.strip() for line in open(sys.argv[1], errors="replace").read().splitlines()
         if line.strip() and not line.startswith(("Timestamp", "Filtering the log data"))]   # log show headers
def norm(line):
    match = re.search(r"com\.iantodd\.glancebar\)\s*(.*)$", line)
    if match and match.group(1).strip():
        return match.group(1).strip()
    match = re.search(r"\]\s*(.*)$", line)
    if match and match.group(1).strip():
        return match.group(1).strip()
    return line
if not lines:
    print("0")
else:
    msg = collections.Counter(norm(line) for line in lines).most_common(1)[0][0]
    print(f"{len(lines)}\t{msg[:120]}")
' "$out")
    if [[ $parsed == 0 ]]; then
      record PASS "Glancebar errors" "0"
    else
      n=${parsed%%$'\t'*}
      msg=${parsed#*$'\t'}
      record WARN "Glancebar errors" "$n, $msg"
    fi
  fi
  rm -f "$out" "$err"
}

probe_helper() {
  # The Geely helper rewrites vehicle-cloud.json on every 10-minute poll, misses included
  # (it keeps the last good reading and adds "error"). ~/.config/energybar/vehicle.json
  # is Energybar's own settings file, not the helper's output.
  local poll="$MORNING_HOME/.cache/energybar/vehicle-cloud.json"
  local mtime now age err
  if [[ ! -e $poll ]]; then
    note_info "Energybar helper" "vehicle-cloud.json absent"
    return
  fi
  mtime=$(stat -f %m "$poll")
  now=$EPOCHSECONDS
  age=$(( (now - mtime) / 60 ))
  err=$(/usr/bin/sed -nE 's/.*"error": *"([^"]*)".*/\1/p' "$poll" | head -1)
  if (( now - mtime > 1800 )); then
    record WARN "Energybar helper" "vehicle-cloud.json ${age}m old"
  elif [[ $err == "signed out" || $err == "not linked" ]]; then
    record WARN "Energybar helper" "$err (geely_soc.py send-code, then verify)"
  elif [[ -n $err ]]; then
    record PASS "Energybar helper" "polled ${age}m ago, last try $err"
  else
    record PASS "Energybar helper" "vehicle-cloud.json ${age}m old"
  fi
}

probe_one_worker() {
  local host=$1 local_ver=$2
  local out err rc line ver ts age_s
  local -a problems
  out=$(mktemp)
  err=$(mktemp)
  problems=()
  run_timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" \
    'v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/Glancebar.app/Contents/Info.plist 2>/dev/null || printf missing); d=$HOME/.local/state/machine-analytics; n=$(find "$d" -type f -exec stat -f %m {} + 2>/dev/null | sort -n | tail -1); printf "%s %s\n" "${v:-missing}" "${n:-0}"' \
    < /dev/null >"$out" 2>"$err"
  rc=$?
  if (( rc != 0 )); then
    record FAIL "worker $host" "unreachable"
    rm -f "$out" "$err"
    return
  fi
  line=$(head -n 1 "$out" 2>/dev/null || true)
  ver=${line%% *}
  ts=${line##* }
  [[ -n $ver ]] || ver=missing
  if [[ $ver != "$local_ver" ]]; then
    problems+=("Glancebar $ver != $local_ver")
  fi
  if [[ $ts == <-> ]]; then
    age_s=$((EPOCHSECONDS - ts))
    (( age_s < 0 )) && age_s=0
    if (( age_s >= 900 )); then
      problems+=("machine-log $((age_s / 60))m")
    fi
  else
    problems+=("machine-log missing")
  fi
  if (( ${#problems} )); then
    record WARN "worker $host" "${(j:, :)problems}"
  else
    age_s=$((EPOCHSECONDS - ts))
    (( age_s < 0 )) && age_s=0
    record PASS "worker $host" "Glancebar $ver, machine-log $((age_s / 60))m"
  fi
  rm -f "$out" "$err"
}

probe_workers() {
  local hosts="$MORNING_HOME/.config/remote-run/hosts"
  local local_ver line trimmed host any
  if [[ ! -f $hosts ]]; then
    record WARN "workers" "hosts file missing"
    return
  fi
  local_ver=$(plist_version "$MORNING_APPS_DIR/Glancebar.app/Contents/Info.plist" || true)
  [[ -n $local_ver ]] || local_ver=missing
  any=0
  while IFS= read -r line || [[ -n $line ]]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    [[ -z $trimmed || $trimmed == \#* ]] && continue
    host=${trimmed%%[[:space:]]*}
    [[ -z $host ]] && continue
    any=1
    probe_one_worker "$host" "$local_ver"
  done < "$hosts"
  if (( any == 0 )); then
    record PASS "workers" "none"
  fi
}

probe_idrive() {
  local py out err rc parsed idrive_status failures age rest fact bad
  py=$(mktemp)
  out=$(mktemp)
  err=$(mktemp)
  cat > "$py" <<'PY'
import datetime, glob, os, re, sys, xml.etree.ElementTree as ET
home = sys.argv[1]
now = datetime.datetime.now()
pattern = os.path.join(home, "Library/Application Support/IDriveforMac/SessionLogsNew/LOGXML", "*.xml")
best = None
for path in glob.glob(pattern):
    try:
        raw = open(path, "rb").read()
        # Local logs only. Reject a DTD so a planted file cannot expand entities.
        if b"<!DOCTYPE" in raw.upper() or b"<!ENTITY" in raw.upper():
            continue
        root = ET.fromstring(raw)
    except (ET.ParseError, OSError):
        continue
    for rec in root.iter("record"):
        text = (rec.findtext("datetime") or "").strip()
        try:
            stamp = datetime.datetime.strptime(text, "%m-%d-%Y %H:%M:%S")
        except ValueError:
            continue
        if best is None or stamp > best[0]:
            best = (stamp, rec)
if best is None:
    print("NONE")
    raise SystemExit
stamp, rec = best
status = (rec.findtext("status") or "").strip()
logfile = (rec.findtext("logfile") or "").strip()
failures = 0
summary = logfile + ".summary" if logfile else ""
if summary and os.path.isfile(summary):
    body = open(summary, errors="replace").read()
    match = re.search(r"Files failed to backup:\s*(\d+)", body, re.I)
    if match:
        failures = int(match.group(1))
age = max(0, int((now - stamp).total_seconds()))
print(f"{status}\t{failures}\t{age}")
PY
  run_timeout 30 /usr/bin/python3 "$py" "$MORNING_HOME" >"$out" 2>"$err"
  rc=$?
  parsed=$(<"$out")
  parsed=${parsed%%$'\n'*}
  rm -f "$py" "$out" "$err"
  if (( rc != 0 )) || [[ -z $parsed || $parsed == NONE ]]; then
    record WARN "iDrive" "no session log"
    return
  fi
  idrive_status=${parsed%%$'\t'*}
  rest=${parsed#*$'\t'}
  failures=${rest%%$'\t'*}
  age=${rest#*$'\t'}
  [[ $failures == <-> ]] || failures=0
  [[ $age == <-> ]] || age=0
  if (( age < 3600 )); then
    fact="$idrive_status, $failures files failed, $((age / 60))m"
  else
    fact="$idrive_status, $failures files failed, $((age / 3600))h"
  fi
  # Failure here often means one temp file vanished. The summary count is the signal.
  bad=0
  case $idrive_status in
    Success|Success\*|Failure) ;;
    *) bad=1 ;;
  esac
  if (( bad || failures > 20 || age >= 30 * 3600 )); then
    record WARN "iDrive" "$fact"
  else
    record PASS "iDrive" "$fact"
  fi
}

probe_stash() {
  local now=$EPOCHSECONDS found=0 latest="" f fm line stamp epoch
  local files=(
    "$MORNING_HOME/.local/state/stash/reclaim.log"
    "$MORNING_HOME/.local/state/stash/reclaim.err"
  )
  for f in "${files[@]}"; do
    [[ -f $f ]] || continue
    fm=$(stat -f %m "$f")
    while IFS= read -r line || [[ -n $line ]]; do
      [[ -n ${line//[[:space:]]/} ]] || continue
      stamp=${line[1,19]}
      epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$stamp" +%s 2>/dev/null || true)
      if [[ $epoch == <-> ]]; then
        if (( epoch <= now && now - epoch <= 86400 )); then
          found=$((found + 1))
          latest=$line
        fi
      elif (( now - fm <= 86400 )); then
        found=$((found + 1))
        latest=$line
      fi
    done < <(run_timeout 10 tail -n 400 "$f" || true)
  done
  if (( found > 0 )); then
    latest=${latest//$'\t'/ }
    record WARN "stash" "$found in 24h: ${latest:0:140}"
  else
    record PASS "stash" "quiet"
  fi
}

RUN_STARTED=1
probe_install "Glancebar install" "$MORNING_GLANCEBAR_REPO" "Glancebar.app" "Glancebar"
probe_running "Glancebar running" "Glancebar" "$MORNING_APPS_DIR/Glancebar.app/Contents/MacOS/Glancebar"
if (( ! QUICK )); then
  probe_tests "Glancebar tests" "$MORNING_GLANCEBAR_REPO"
fi
probe_errors
probe_install "Energybar install" "$MORNING_ENERGYBAR_REPO" "Energybar.app" "Energybar"
probe_running "Energybar running" "Energybar" "$MORNING_APPS_DIR/Energybar.app/Contents/MacOS/Energybar"
if (( ! QUICK )); then
  probe_tests "Energybar tests" "$MORNING_ENERGYBAR_REPO"
fi
probe_helper
probe_workers
probe_idrive
probe_stash
exit 0
