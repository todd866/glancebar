#!/bin/bash
# Checks for glancebar-sync. No network, no ssh, no build, no install: the repository,
# its origin, the state folder and the stand-ins for tests, deploy and mail all live
# under one temp directory.
set -u
fail=0
here=$(cd "$(dirname "$0")" && pwd)
SYNC="$here/glancebar-sync"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/glancebar-sync.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

ok() { printf 'ok %s\n' "$1"; }
not_ok() { printf 'not ok %s\n' "$1"; fail=$((fail + 1)); }
gitc() { /usr/bin/git -c user.email=glancebar@example.com -c user.name=Glancebar "$@"; }

# A fresh origin, a clone of it, and stand-ins that record what was called.
setup() {
  CASE="$WORK/$1"; mkdir -p "$CASE/bin" "$CASE/update-state"
  gitc init -q -b main "$CASE/origin"
  echo one > "$CASE/origin/file"; gitc -C "$CASE/origin" add file; gitc -C "$CASE/origin" commit -qm one
  gitc clone -q "$CASE/origin" "$CASE/repo"
  cat > "$CASE/bin/deploy" <<EOF
#!/bin/bash
echo deploy >> "$CASE/calls"
[ -f "$CASE/deploy-fails" ] && { echo "publish failed: boom"; exit 1; }
/usr/bin/git -C "\$1" rev-parse HEAD > "$CASE/update-state/installed"
EOF
  cat > "$CASE/bin/tests" <<EOF
#!/bin/bash
echo tests >> "$CASE/calls"
[ -f "$CASE/tests-fail" ] && exit 1
exit 0
EOF
  cat > "$CASE/bin/mail" <<EOF
#!/bin/bash
echo "mail \$*" >> "$CASE/calls"
EOF
  chmod +x "$CASE/bin/deploy" "$CASE/bin/tests" "$CASE/bin/mail"
  : > "$CASE/calls"
}
advance() { echo "$1" >> "$CASE/origin/file"; gitc -C "$CASE/origin" commit -qam "$1"; }
run() {
  GLANCEBAR_SYNC_CHIP="${CHIP:-Apple M5}" GLANCEBAR_REPO="$CASE/repo" GLANCEBAR_SYNC_STATE="$CASE/state" \
    GLANCEBAR_STATE_DIR="$CASE/update-state" GLANCEBAR_DEPLOY_BIN="$CASE/bin/deploy" \
    GLANCEBAR_TESTS_CMD="$CASE/bin/tests" GLANCEBAR_MAIL_BIN="$CASE/bin/mail" "$SYNC" "$@" > "$CASE/out" 2>&1
}
calls() { tr '\n' ' ' < "$CASE/calls" | sed 's/ $//'; }
installed() { cat "$CASE/update-state/installed" 2>/dev/null; }
origin_head() { /usr/bin/git -C "$CASE/origin" rev-parse HEAD; }

setup behind
run; rc=$?
[ $rc = 0 ] && [ "$(calls)" = "tests deploy" ] && [ "$(installed)" = "$(origin_head)" ] \
  && ok "nothing installed: tests, then deploy" || not_ok "nothing installed: tests, then deploy (rc $rc, calls '$(calls)')"
: > "$CASE/calls"; run
[ -z "$(calls)" ] && ok "in sync: nothing runs" || not_ok "in sync: nothing runs ('$(calls)')"
advance two; : > "$CASE/calls"; run
[ "$(calls)" = "tests deploy" ] && [ "$(installed)" = "$(origin_head)" ] \
  && ok "origin moved: checkout fast-forwards and deploys" || not_ok "origin moved: checkout fast-forwards and deploys ('$(calls)')"

setup red
touch "$CASE/tests-fail"; run; rc=$?
[ $rc = 1 ] && [ "$(calls | cut -d' ' -f1-2)" = "tests mail" ] && [ -z "$(installed)" ] \
  && ok "red tests: not deployed, mailed once" || not_ok "red tests: not deployed, mailed once (rc $rc, '$(calls)')"
: > "$CASE/calls"; run; rc=$?
[ $rc = 0 ] && [ -z "$(calls)" ] && ok "same commit is not retried" || not_ok "same commit is not retried (rc $rc, '$(calls)')"
rm "$CASE/tests-fail"; advance fix; : > "$CASE/calls"; run
[ "$(calls)" = "tests deploy" ] && [ ! -f "$CASE/state/failed" ] \
  && ok "main moved: tried again and the failure mark is cleared" || not_ok "main moved: tried again ('$(calls)')"

setup deployfail
touch "$CASE/deploy-fails"; run; rc=$?
[ $rc = 1 ] && grep -q "publish failed: boom" "$CASE/state/failed" && grep -q "^mail " "$CASE/calls" \
  && ok "deploy failure is recorded with its reason and mailed" || not_ok "deploy failure is recorded (rc $rc)"

setup dirty
echo edit >> "$CASE/repo/file"; run; rc=$?
[ $rc = 0 ] && [ -z "$(calls)" ] && grep -q "tracked files are modified" "$CASE/out" \
  && ok "tracked edits in the checkout: skipped" || not_ok "tracked edits in the checkout: skipped (rc $rc, '$(calls)')"

setup branch
gitc -C "$CASE/repo" checkout -q -b feature; run; rc=$?
[ $rc = 0 ] && [ -z "$(calls)" ] && ok "off main: skipped" || not_ok "off main: skipped ('$(calls)')"

setup worker
CHIP="Apple M2" run; rc=$?; unset CHIP
[ $rc = 0 ] && [ -z "$(calls)" ] && ok "not the signing Mac: does nothing" || not_ok "not the signing Mac: does nothing ('$(calls)')"

setup status
run --status
grep -q "^behind" "$CASE/out" && [ -z "$(calls)" ] && ok "--status reports and changes nothing" || not_ok "--status reports and changes nothing"

[ $fail = 0 ] && echo "all glancebar-sync checks passed" || echo "$fail glancebar-sync check(s) failed"
exit $fail
