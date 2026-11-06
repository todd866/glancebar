#!/bin/bash
# Local fleet-sync checks. No network, no ssh, no push, no install into /Applications.
# HOME and every repository stay under one temp directory.
set -u
fail=0
here=$(cd "$(dirname "$0")" && pwd)
UPDATE="$here/glancebar-update"
RELEASE="$here/glancebar-release"
DEPLOY="$here/glancebar-deploy"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/glancebar-fleet.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

ok() { printf 'ok %s\n' "$1"; }
not_ok() { printf 'not ok %s\n' "$1"; fail=$((fail + 1)); }

gitc() { /usr/bin/git -c user.email=glancebar@example.com -c user.name=Glancebar "$@"; }

install_guard() {
  local bin="$1" trace="$2"
  mkdir -p "$bin"
  cat > "$bin/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = push ]; then echo "push \$*" >> "$trace"; exit 99; fi
exec /usr/bin/git "\$@"
EOF
  cat > "$bin/codesign" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$bin/git" "$bin/codesign"
}

status_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}

# --- glancebar-update -------------------------------------------------------
new_pair() {
  local name="$1" origin clone
  origin="$WORK/$name-origin"
  clone="$WORK/$name-home/Projects/glancebar"
  mkdir -p "$origin/Sources" "$WORK/$name-home/Projects" "$WORK/$name-bin" \
    "$WORK/$name-home/.local/bin" "$WORK/$name-home/Applications" "$WORK/$name-app-parent"
  printf 'base\n' > "$origin/Sources/tracked.txt"
  gitc -C "$origin" init -q -b main
  gitc -C "$origin" add Sources/tracked.txt
  gitc -C "$origin" commit -q -m base
  gitc clone -q "$origin" "$clone"
  install_guard "$WORK/$name-bin" "$WORK/$name-trace"
  PAIR_HOME="$WORK/$name-home"
  PAIR_CLONE="$clone"
  PAIR_ORIGIN="$origin"
  PAIR_BIN="$WORK/$name-bin"
  PAIR_TRACE="$WORK/$name-trace"
  PAIR_APP="$WORK/$name-app-parent/Glancebar.app"
  PAIR_STUB="$WORK/$name-release"
}

run_update() {
  local fail_release="${1:-0}"
  cat > "$PAIR_STUB" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/release-log"
if [ "$fail_release" = 1 ]; then exit 1; fi
mkdir -p "\$3/Contents/MacOS"
printf 'stub\n' > "\$3/Contents/MacOS/Glancebar"
exit 0
EOF
  chmod +x "$PAIR_STUB"
  touch "$WORK/release-log"
  HOME="$PAIR_HOME" \
    GLANCEBAR_PATH_PREFIX="$PAIR_BIN" \
    GLANCEBAR_REPO="$PAIR_CLONE" \
    GLANCEBAR_RELEASE_BIN="$PAIR_STUB" \
    GLANCEBAR_APP="$PAIR_APP" \
    /bin/bash "$UPDATE"
}

# An untracked file is not a local edit, so the run continues and asks for a release.
new_pair stray
printf 'junk\n' > "$PAIR_CLONE/stray.txt"
if run_update 1; then ok "untracked: update exits 0"; else not_ok "untracked: update exits 0"; fi
state=$(status_field "$PAIR_HOME/.local/state/glancebar-update/status.json" state 2>/dev/null || echo missing)
if [ "$state" = "no-release" ]; then ok "untracked: does not skip"; else not_ok "untracked: does not skip ($state)"; fi
if [ -f "$PAIR_CLONE/stray.txt" ]; then ok "untracked: stray file stays"; else not_ok "untracked: stray file stays"; fi
if ! grep -q 'push ' "$PAIR_TRACE" 2>/dev/null; then ok "untracked: does not push"; else not_ok "untracked: does not push"; fi

# A tracked edit skips the fast-forward even when origin has moved on.
new_pair dirty
printf 'more\n' >> "$PAIR_ORIGIN/Sources/tracked.txt"
gitc -C "$PAIR_ORIGIN" commit -q -am 'origin moves'
before=$(gitc -C "$PAIR_CLONE" rev-parse HEAD)
printf 'local\n' >> "$PAIR_CLONE/Sources/tracked.txt"
if run_update 0; then ok "tracked: update exits 0"; else not_ok "tracked: update exits 0"; fi
state=$(status_field "$PAIR_HOME/.local/state/glancebar-update/status.json" state 2>/dev/null || echo missing)
after=$(gitc -C "$PAIR_CLONE" rev-parse HEAD)
if [ "$state" = "local-changes" ] && [ "$before" = "$after" ]; then ok "tracked: edit skips the fast-forward"; else not_ok "tracked: edit skips the fast-forward ($state)"; fi
if grep -q 'local' "$PAIR_CLONE/Sources/tracked.txt"; then ok "tracked: edit is kept"; else not_ok "tracked: edit is kept"; fi

# An untracked file that would be overwritten is moved aside, then the update installs.
new_pair clash
mkdir -p "$PAIR_ORIGIN/nested"
printf 'from-origin\n' > "$PAIR_ORIGIN/nested/blocked.txt"
gitc -C "$PAIR_ORIGIN" add nested/blocked.txt
gitc -C "$PAIR_ORIGIN" commit -q -m 'add blocked'
mkdir -p "$PAIR_CLONE/nested" "$PAIR_HOME/Applications/Glancebar.app/Contents"
printf 'local-copy\n' > "$PAIR_CLONE/nested/blocked.txt"
printf 'marker\n' > "$PAIR_HOME/Applications/Glancebar.app/Contents/marker"
if run_update 0; then ok "clash: update exits 0"; else not_ok "clash: update exits 0"; fi
got=$(cat "$PAIR_CLONE/nested/blocked.txt" 2>/dev/null || echo missing)
if [ "$got" = "from-origin" ]; then ok "clash: fast-forward lands the tracked file"; else not_ok "clash: fast-forward lands the tracked file ($got)"; fi
aside=$(find "$PAIR_HOME/.local/state/glancebar-update" -path '*/untracked-*/nested/blocked.txt' 2>/dev/null | head -n 1)
aside_got=$(cat "$aside" 2>/dev/null || echo missing)
if [ "$aside_got" = "local-copy" ]; then ok "clash: untracked file is moved aside"; else not_ok "clash: untracked file is moved aside ($aside_got)"; fi
head=$(gitc -C "$PAIR_CLONE" rev-parse HEAD)
installed=$(status_field "$PAIR_HOME/.local/state/glancebar-update/status.json" installed 2>/dev/null || echo missing)
behind=$(status_field "$PAIR_HOME/.local/state/glancebar-update/status.json" behind 2>/dev/null || echo missing)
state=$(status_field "$PAIR_HOME/.local/state/glancebar-update/status.json" state 2>/dev/null || echo missing)
if [ "$state" = "ok" ] && [ "$installed" = "$head" ] && [ "$behind" = "0" ]; then ok "clash: status records the installed commit"; else not_ok "clash: status records the installed commit ($state $installed $behind)"; fi
if [ -f "$PAIR_APP/Contents/MacOS/Glancebar" ] && ! [ -d "$PAIR_HOME/Applications/Glancebar.app" ]; then ok "clash: one app, installed at the requested path"; else not_ok "clash: one app, installed at the requested path"; fi
marker=$(find "$PAIR_HOME/.local/state/glancebar-update" -path '*/previous-home-*.app/Contents/marker' 2>/dev/null | head -n 1)
if [ -n "$marker" ]; then ok "clash: home copy is parked, not deleted"; else not_ok "clash: home copy is parked, not deleted"; fi
log_lines=$(wc -l < "$WORK/release-log" | tr -d ' ')
if run_update 0; then ok "clash: second run exits 0"; else not_ok "clash: second run exits 0"; fi
log_lines2=$(wc -l < "$WORK/release-log" | tr -d ' ')
if [ "$log_lines" = "$log_lines2" ]; then ok "clash: second run does not fetch again"; else not_ok "clash: second run does not fetch again"; fi

# A live lock is left alone.
new_pair lock
mkdir -p "$PAIR_HOME/.local/state/glancebar-update/lock"
echo $$ > "$PAIR_HOME/.local/state/glancebar-update/lock/pid"
printf '%s\n' '{"state":"untouched"}' > "$PAIR_HOME/.local/state/glancebar-update/status.json"
lock_before=$(wc -l < "$WORK/release-log" | tr -d ' ')
if run_update 0; then ok "lock: exits 0"; else not_ok "lock: exits 0"; fi
lock_after=$(wc -l < "$WORK/release-log" | tr -d ' ')
if grep -q untouched "$PAIR_HOME/.local/state/glancebar-update/status.json"; then ok "lock: does not rewrite status"; else not_ok "lock: does not rewrite status"; fi
if [ -d "$PAIR_HOME/.local/state/glancebar-update/lock" ]; then ok "lock: holder keeps the lock"; else not_ok "lock: holder keeps the lock"; fi
if [ "$lock_before" = "$lock_after" ]; then ok "lock: does not fetch a release"; else not_ok "lock: does not fetch a release"; fi

# Off main is a recorded skip, not a merge.
new_pair side
gitc -C "$PAIR_CLONE" checkout -q -b side
if run_update 0; then ok "branch: update exits 0"; else not_ok "branch: update exits 0"; fi
state=$(status_field "$PAIR_HOME/.local/state/glancebar-update/status.json" state 2>/dev/null || echo missing)
if [ "$state" = "not-main" ]; then ok "branch: not on main is recorded"; else not_ok "branch: not on main is recorded ($state)"; fi

# --- glancebar-release ------------------------------------------------------
if ! grep -q 'build-remote' "$RELEASE" 2>/dev/null; then
  not_ok "release: publish builds with tools/build-remote.sh"
else
  rel="$WORK/rel"
  home="$rel/home"
  bin="$rel/bin"
  origin="$rel/origin.git"
  src="$rel/src"
  mkdir -p "$home/.local/bin" "$bin" "$src/Sources" "$src/tools"
  install_guard "$bin" "$rel/trace"
  cat > "$home/.local/bin/heavy-slot" <<EOF
#!/bin/bash
echo "heavy-slot \$*" >> "$rel/trace"
mkdir -p build/Glancebar.app/Contents/MacOS
printf 'local\n' > build/Glancebar.app/Contents/MacOS/Glancebar
exit 0
EOF
  chmod +x "$home/.local/bin/heavy-slot"
  printf '0\n' > "$rel/remote-exit"
  cat > "$src/tools/build-remote.sh" <<EOF
#!/bin/bash
code=\$(cat "$rel/remote-exit")
echo "build-remote \$code" >> "$rel/trace"
if [ "\$code" != 0 ]; then
  if [ "\$code" = 9 ]; then echo "remote-run: no worker reachable" >&2; fi
  exit "\$code"
fi
mkdir -p build/Glancebar.app/Contents/MacOS
printf 'remote\n' > build/Glancebar.app/Contents/MacOS/Glancebar
exit 0
EOF
  chmod +x "$src/tools/build-remote.sh"
  printf 'int x;\n' > "$src/Sources/main.c"
  printf 'echo build\n' > "$src/build.sh"
  chmod +x "$src/build.sh"
  gitc -C "$src" init -q -b main
  gitc -C "$src" add Sources/main.c tools/build-remote.sh build.sh
  gitc -C "$src" commit -q -m init
  gitc init -q --bare "$origin"
  gitc -C "$src" remote add origin "$origin"
  gitc -C "$src" push -q origin main
  export HOME="$home" PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin" GLANCEBAR_RELEASE_STORE="$home/.local/state/glancebar-releases"
  d1=$(python3 "$RELEASE" digest "$src")
  mkdir -p "$src/Sources/__pycache__"
  printf 'junk\n' > "$src/Sources/__pycache__/x.pyc"
  printf 'junk\n' > "$src/Sources/untracked.c"
  d2=$(python3 "$RELEASE" digest "$src")
  if [ -n "$d1" ] && [ "$d1" = "$d2" ]; then ok "release: untracked and ignored files do not change the digest"; else not_ok "release: untracked and ignored files do not change the digest"; fi
  printf 'int y;\n' > "$src/Sources/main.c"
  d3=$(python3 "$RELEASE" digest "$src")
  if [ "$d3" != "$d1" ]; then ok "release: a tracked edit changes the digest"; else not_ok "release: a tracked edit changes the digest"; fi
  if python3 "$RELEASE" publish "$src" >"$rel/out" 2>"$rel/err"; then not_ok "release: dirty tree is refused"; else ok "release: dirty tree is refused"; fi
  if grep -q 'tracked files are modified' "$rel/err"; then ok "release: dirty tree says why"; else not_ok "release: dirty tree says why"; fi
  gitc -C "$src" checkout -q -- Sources/main.c
  : > "$rel/trace"
  if python3 "$RELEASE" publish "$src" >"$rel/out" 2>"$rel/err"; then ok "release: clean origin/main publishes"; else not_ok "release: clean origin/main publishes"; fi
  if grep -q 'build-remote 0' "$rel/trace" && ! grep -q heavy-slot "$rel/trace"; then ok "release: a reachable worker does not fall back"; else not_ok "release: a reachable worker does not fall back"; fi
  published=$(cat "$rel/out")
  mkdir -p "$rel/fetched"
  if python3 "$RELEASE" fetch "$src" "$rel/fetched/Glancebar.app" >"$rel/fout" 2>"$rel/ferr"; then ok "release: fetch verifies the published app"; else not_ok "release: fetch verifies the published app"; fi
  if [ -f "$rel/fetched/Glancebar.app/Contents/MacOS/Glancebar" ]; then ok "release: fetch writes the app"; else not_ok "release: fetch writes the app"; fi
  printf 'int y;\n' > "$src/Sources/main.c"
  if python3 "$RELEASE" fetch "$src" "$rel/fetched2/Glancebar.app" >"$rel/fout2" 2>"$rel/ferr2"; then not_ok "release: a tracked edit does not match the release"; else ok "release: a tracked edit does not match the release"; fi
  gitc -C "$src" checkout -q -- Sources/main.c
  printf 'still-ignored\n' > "$src/Sources/untracked.c"
  mkdir -p "$rel/fetched3"
  if python3 "$RELEASE" fetch "$src" "$rel/fetched3/Glancebar.app" >"$rel/fout3" 2>"$rel/ferr3"; then ok "release: fetch ignores untracked files"; else not_ok "release: fetch ignores untracked files"; fi
  rm -rf "$published"
  printf '75\n' > "$rel/remote-exit"
  : > "$rel/trace"
  if python3 "$RELEASE" publish "$src" >"$rel/out" 2>"$rel/err"; then ok "release: exit 75 falls back to heavy-slot"; else not_ok "release: exit 75 falls back to heavy-slot"; fi
  if grep -q 'build-remote 75' "$rel/trace" && grep -q heavy-slot "$rel/trace"; then ok "release: fallback actually ran heavy-slot"; else not_ok "release: fallback actually ran heavy-slot"; fi
  rm -rf "$published"
  printf '4\n' > "$rel/remote-exit"
  : > "$rel/trace"
  if python3 "$RELEASE" publish "$src" >"$rel/out" 2>"$rel/err"; then ok "release: no reachable worker falls back"; else not_ok "release: no reachable worker falls back"; fi
  if grep -q heavy-slot "$rel/trace"; then ok "release: exit 4 used the local build"; else not_ok "release: exit 4 used the local build"; fi
  rm -rf "$published"
  printf '1\n' > "$rel/remote-exit"
  : > "$rel/trace"
  if python3 "$RELEASE" publish "$src" >"$rel/out" 2>"$rel/err"; then not_ok "release: a real build failure does not fall back"; else ok "release: a real build failure does not fall back"; fi
  if grep -q heavy-slot "$rel/trace"; then not_ok "release: exit 1 did not call heavy-slot"; else ok "release: exit 1 did not call heavy-slot"; fi
  printf '0\n' > "$rel/remote-exit"
  printf 'int z;\n' > "$src/Sources/main.c"
  gitc -C "$src" commit -q -am 'unpushed'
  if python3 "$RELEASE" publish "$src" >"$rel/out" 2>"$rel/err"; then not_ok "release: unpushed HEAD is refused"; else ok "release: unpushed HEAD is refused"; fi
  if grep -q 'origin/main' "$rel/err"; then ok "release: unpushed refusal names origin/main"; else not_ok "release: unpushed refusal names origin/main"; fi
  if python3 "$RELEASE" --allow-unpushed publish "$src" >"$rel/out" 2>"$rel/err"; then ok "release: --allow-unpushed overrides only the push check"; else not_ok "release: --allow-unpushed overrides only the push check"; fi
  printf 'int w;\n' > "$src/Sources/main.c"
  if python3 "$RELEASE" --allow-unpushed publish "$src" >"$rel/out" 2>"$rel/err"; then not_ok "release: --allow-unpushed still refuses a dirty tree"; else ok "release: --allow-unpushed still refuses a dirty tree"; fi
  unset HOME GLANCEBAR_RELEASE_STORE
fi

# --- glancebar-deploy -------------------------------------------------------
if [ ! -f "$DEPLOY" ]; then
  not_ok "deploy: script exists"
else
  dhome="$WORK/deploy-home"
  dsrc="$WORK/deploy-src"
  dbin="$WORK/deploy-bin"
  dtrace="$WORK/deploy-trace"
  mkdir -p "$dhome" "$dsrc/Sources" "$dbin"
  install_guard "$dbin" "$dtrace"
  printf 'int x;\n' > "$dsrc/Sources/main.c"
  gitc -C "$dsrc" init -q -b main
  gitc -C "$dsrc" add Sources/main.c
  gitc -C "$dsrc" commit -q -m init
  write_chip() {
    cat > "$dbin/sysctl" <<EOF
#!/bin/bash
if [ "\${1:-}" = "-n" ] && [ "\${2:-}" = "machdep.cpu.brand_string" ]; then printf '%s\n' "$1"; exit 0; fi
exec /usr/sbin/sysctl "\$@"
EOF
    chmod +x "$dbin/sysctl"
  }
  write_chip "Apple M1"
  if HOME="$dhome" GLANCEBAR_PATH_PREFIX="$dbin" /bin/bash "$DEPLOY" "$dsrc" >"$WORK/deploy-out" 2>"$WORK/deploy-err"; then
    not_ok "deploy: refuses a Mac that is not the M5"
  else
    ok "deploy: refuses a Mac that is not the M5"
  fi
  if grep -q 'not the M5' "$WORK/deploy-out"; then ok "deploy: names the chip"; else not_ok "deploy: names the chip"; fi
  write_chip "Apple M5"
  printf 'local\n' >> "$dsrc/Sources/main.c"
  : > "$dtrace"
  if HOME="$dhome" GLANCEBAR_PATH_PREFIX="$dbin" /bin/bash "$DEPLOY" "$dsrc" >"$WORK/deploy-out" 2>"$WORK/deploy-err"; then
    not_ok "deploy: refuses tracked edits"
  else
    ok "deploy: refuses tracked edits"
  fi
  if grep -q 'tracked files are modified' "$WORK/deploy-out" && ! grep -q 'push ' "$dtrace"; then ok "deploy: dirty refusal does not push"; else not_ok "deploy: dirty refusal does not push"; fi
  gitc -C "$dsrc" checkout -q -- Sources/main.c
  gitc -C "$dsrc" checkout -q -b side
  : > "$dtrace"
  if HOME="$dhome" GLANCEBAR_PATH_PREFIX="$dbin" /bin/bash "$DEPLOY" "$dsrc" >"$WORK/deploy-out" 2>"$WORK/deploy-err"; then
    not_ok "deploy: refuses a branch other than main"
  else
    ok "deploy: refuses a branch other than main"
  fi
  if grep -q 'not on main' "$WORK/deploy-out" && ! grep -q 'push ' "$dtrace"; then ok "deploy: branch refusal does not push"; else not_ok "deploy: branch refusal does not push"; fi
fi

if [ "$fail" -eq 0 ]; then printf 'ALL FLEET TESTS PASSED\n'; else printf 'FLEET TESTS FAILED (%s)\n' "$fail"; fi
exit "$fail"
