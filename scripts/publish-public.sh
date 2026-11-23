#!/bin/bash
set -euo pipefail

PUSH=0
for arg in "$@"; do
  case "$arg" in
    --push)
      PUSH=1
      ;;
    -h|--help)
      echo "Usage: $0 [--push]"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      echo "Usage: $0 [--push]" >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF="${REF:-main}"
REPO="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)"
PUBLIC_DIR="${GLANCEBAR_PUBLIC_DIR:-$HOME/Projects/glancebar-public}"

DENYLIST="${PUBLIC_DENYLIST:-$HOME/.config/glancebar/public-denylist.txt}"
if [[ -n "${PUBLIC_DENYLIST:-}" ]]; then
  if [[ ! -f "$DENYLIST" || ! -r "$DENYLIST" ]]; then
    echo "ERROR: PUBLIC_DENYLIST does not exist or is unreadable: $DENYLIST" >&2
    exit 2
  fi
fi

IMAGES_OK="${PUBLIC_IMAGES_OK:-$REPO/scripts/public-images-approved.txt}"
if [[ ! -f "$IMAGES_OK" || ! -r "$IMAGES_OK" ]]; then
  echo "ERROR: image allowlist missing or unreadable: $IMAGES_OK" >&2
  exit 2
fi

EXCLUDE_FILE="$REPO/.public-exclude"
if [[ ! -f "$EXCLUDE_FILE" || ! -r "$EXCLUDE_FILE" ]]; then
  echo "ERROR: .public-exclude missing or unreadable: $EXCLUDE_FILE" >&2
  exit 2
fi

for cmd in git tar rg python3 shasum gitleaks rsync zsh; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 2
  fi
done

if [[ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]]; then
  echo "ERROR: tracked files in $REPO are dirty; commit or stash before publishing" >&2
  exit 1
fi

if ! git -C "$REPO" rev-parse --verify "$REF^{commit}" >/dev/null 2>&1; then
  echo "ERROR: ref '$REF' is not a valid commit in $REPO" >&2
  exit 1
fi

if [[ ! -d "$PUBLIC_DIR/.git" ]]; then
  echo "ERROR: $PUBLIC_DIR/.git is missing" >&2
  exit 1
fi

REPO_ORIGIN="$(git -C "$REPO" remote get-url origin)"
PUBLIC_ORIGIN="$(git -C "$PUBLIC_DIR" remote get-url origin)"
if [[ -z "$PUBLIC_ORIGIN" ]]; then
  echo "ERROR: $PUBLIC_DIR has no origin remote" >&2
  exit 1
fi
if [[ "$PUBLIC_ORIGIN" == "$REPO_ORIGIN" ]]; then
  echo "ERROR: $PUBLIC_DIR origin equals private repo origin ($PUBLIC_ORIGIN)" >&2
  exit 1
fi
if [[ "$PUBLIC_ORIGIN" == *-private* ]]; then
  echo "ERROR: $PUBLIC_DIR origin matches *-private* ($PUBLIC_ORIGIN)" >&2
  exit 1
fi

if [[ -n "$(git -C "$PUBLIC_DIR" status --porcelain)" ]]; then
  echo "ERROR: $PUBLIC_DIR working tree is not clean" >&2
  exit 1
fi

EXPORT="$(mktemp -d)"
cleanup() {
  rm -rf "$EXPORT"
}
trap cleanup EXIT

git -C "$REPO" archive "$REF" | tar -x -C "$EXPORT"

echo "==> Gate 1: .public-exclude and .DS_Store"
python3 - "$EXPORT" "$EXCLUDE_FILE" <<'PY'
import glob
import os
import pathlib
import shutil
import sys

export_root = pathlib.Path(sys.argv[1]).resolve()
exclude_file = pathlib.Path(sys.argv[2])

patterns = []
for raw in exclude_file.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    line = line.rstrip("/")
    if not line or line.startswith("/") or ".." in pathlib.PurePosixPath(line).parts:
        print(f"ERROR: invalid exclude entry: {raw!r}", file=sys.stderr)
        sys.exit(2)
    patterns.append(line)

def resolve_matches(pat: str):
    if glob.has_magic(pat):
        raw_matches = glob.glob(str(export_root / pat), recursive=True)
        return [pathlib.Path(m) for m in raw_matches]
    candidate = export_root / pat
    return [candidate] if candidate.exists() or candidate.is_symlink() else []

for pat in patterns:
    for match in resolve_matches(pat):
        resolved_parent = match.parent.resolve()
        if resolved_parent != export_root and export_root not in resolved_parent.parents:
            print(f"ERROR: exclude escapes export dir: {pat}", file=sys.stderr)
            sys.exit(2)
        if match.is_symlink() or match.is_file():
            match.unlink()
        elif match.is_dir():
            shutil.rmtree(match)

leftovers = []
for pat in patterns:
    for match in resolve_matches(pat):
        leftovers.append(str(match.relative_to(export_root)))

ds_stores = []
for dirpath, dirnames, filenames in os.walk(export_root):
    for name in filenames + dirnames:
        if name == ".DS_Store":
            p = pathlib.Path(dirpath) / name
            ds_stores.append(str(p.relative_to(export_root)))

if leftovers or ds_stores:
    for item in leftovers:
        print(f"Gate 1 FAIL: excluded path survived: {item}", file=sys.stderr)
    for item in ds_stores:
        print(f"Gate 1 FAIL: .DS_Store present: {item}", file=sys.stderr)
    sys.exit(1)
PY
echo "Gate 1 PASS"

echo "==> Gate 2: external denylist"
if [[ -f "$DENYLIST" && -r "$DENYLIST" ]]; then
  if ! grep -qvE '^(#|[[:space:]]*$)' "$DENYLIST"; then
    echo "ERROR: denylist has no active patterns: $DENYLIST" >&2
    exit 2
  fi
  set +e
  GATE2_HITS="$(cd "$EXPORT" && rg -P -i -l --hidden --no-ignore -f <(grep -v '^#' "$DENYLIST" | grep -v '^[[:space:]]*$') .)"
  GATE2_RC=$?
  set -e
  case "$GATE2_RC" in
    0)
      echo "Gate 2 FAIL: denylist matched in files:" >&2
      printf '%s\n' "$GATE2_HITS" >&2
      exit 1
      ;;
    1)
      echo "Gate 2 PASS"
      ;;
    *)
      echo "Gate 2 ERROR: rg exited $GATE2_RC" >&2
      exit "$GATE2_RC"
      ;;
  esac
else
  echo "Gate 2 NOTE: no denylist at $DENYLIST; continuing to Gates 3-6"
fi

echo "==> Gate 3: generic leak regexes"
python3 - "$EXPORT" <<'PY'
import os
import pathlib
import re
import sys

export_root = pathlib.Path(sys.argv[1]).resolve()

EMAIL_RE = re.compile(r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?![A-Za-z0-9._%+-])")
ALLOWED_EMAIL_DOMAINS = {"users.noreply.github.com", "example.com"}

RULES = [
    ("home-path", re.compile(r"/Users/(?!Shared(?:/|\b)|example(?:/|\b)|[ax](?:/|\b))[A-Za-z0-9._-]+")),
    ("host-name", re.compile("iantodds" + "-macbook-air", re.IGNORECASE)),
    ("tailscale-host", re.compile(r"tail[0-9a-f]+\.ts\.net", re.IGNORECASE)),
    ("private-key-pem", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("r2-endpoint", re.compile(r"[0-9a-f]{32}\.r2\.cloudflarestorage\.com", re.IGNORECASE)),
    ("google-api-key", re.compile(r"AIza[0-9A-Za-z_-]{30,}")),
    ("sk-token", re.compile(r"(?<![A-Za-z0-9_])sk-[0-9A-Za-z]{20,}")),
]

failures = []
for dirpath, _, filenames in os.walk(export_root):
    for name in sorted(filenames):
        path = pathlib.Path(dirpath) / name
        if path.is_symlink():
            continue
        data = path.read_bytes()
        if b"\x00" in data:
            continue
        rel = path.relative_to(export_root)
        text = data.decode("utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            for match in EMAIL_RE.finditer(line):
                domain = match.group(1).lower()
                if domain not in ALLOWED_EMAIL_DOMAINS:
                    failures.append(f"{rel}:{lineno}: personal-email (@{domain})")
            for rule_name, regex in RULES:
                if regex.search(line):
                    failures.append(f"{rel}:{lineno}: {rule_name}")

if failures:
    for item in failures:
        print(f"Gate 3 FAIL: {item}", file=sys.stderr)
    sys.exit(1)
PY
echo "Gate 3 PASS"

echo "==> Gate 4: image SHA-256 allowlist"
python3 - "$EXPORT" "$IMAGES_OK" <<'PY'
import hashlib
import os
import pathlib
import re
import sys

export_root = pathlib.Path(sys.argv[1]).resolve()
allow_file = pathlib.Path(sys.argv[2])

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".icns", ".svg"}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

allowed = set()
for raw in allow_file.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    digest = line.split()[0].lower()
    if not SHA256_RE.match(digest):
        print(f"ERROR: invalid sha256 line in {allow_file}: {raw!r}", file=sys.stderr)
        sys.exit(2)
    allowed.add(digest)

failures = []
for dirpath, _, filenames in os.walk(export_root):
    for name in sorted(filenames):
        path = pathlib.Path(dirpath) / name
        if path.suffix.lower() in IMAGE_EXTS:
            rel = path.relative_to(export_root)
            if path.is_symlink():
                failures.append(f"{rel}: symlinked image not allowed")
                continue
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if digest not in allowed:
                failures.append(f"{rel}: unapproved image sha256 {digest}")

if failures:
    for item in failures:
        print(f"Gate 4 FAIL: {item}", file=sys.stderr)
    sys.exit(1)
PY
echo "Gate 4 PASS"

echo "==> Gate 5: gitleaks"
gitleaks dir "$EXPORT" --no-banner --exit-code 1
echo "Gate 5 PASS"

echo "==> Gate 6: syntax and unit tests"
zsh -n "$EXPORT/build.sh"
zsh -n "$EXPORT/tests.sh"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$EXPORT/tools/music-sync" -v
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$EXPORT/tools/music-remote" -v
echo "Gate 6 PASS"

echo "==> Staging into $PUBLIC_DIR"
git -C "$PUBLIC_DIR" fetch -q origin main
git -C "$PUBLIC_DIR" checkout -q main
git -C "$PUBLIC_DIR" reset -q --hard origin/main
rsync -a --delete --exclude .git "$EXPORT"/ "$PUBLIC_DIR"/
git -C "$PUBLIC_DIR" add -A

if [[ "$PUSH" -eq 0 ]]; then
  echo "==> Dry run diff (--cached --stat):"
  git -C "$PUBLIC_DIR" diff --cached --stat
  git -C "$PUBLIC_DIR" reset -q --hard origin/main
  if [[ -n "$(git -C "$PUBLIC_DIR" status --porcelain)" ]]; then
    echo "ERROR: $PUBLIC_DIR was not clean after dry-run reset" >&2
    exit 1
  fi
  echo "Dry run complete; $PUBLIC_DIR restored cleanly."
  exit 0
fi

if git -C "$PUBLIC_DIR" diff --cached --quiet; then
  echo "No changes to commit in $PUBLIC_DIR."
  exit 0
fi

SHORT_SHA="$(git -C "$REPO" rev-parse --short "$REF")"
SNAP_DATE="$(date -u +%Y-%m-%d)"
GIT_AUTHOR_NAME="todd866" \
GIT_AUTHOR_EMAIL="todd866@users.noreply.github.com" \
GIT_COMMITTER_NAME="todd866" \
GIT_COMMITTER_EMAIL="todd866@users.noreply.github.com" \
git -C "$PUBLIC_DIR" -c commit.gpgsign=false commit -q -m "Snapshot of $SHORT_SHA ($SNAP_DATE)"

IDENTITY_LINE="$(git -C "$PUBLIC_DIR" log -1 --format='%an <%ae> / %cn <%ce>')"
echo "Public commit identity: $IDENTITY_LINE"
if ! printf '%s\n' "$IDENTITY_LINE" | grep -qv gmail; then
  echo "ERROR: public commit identity failed check: $IDENTITY_LINE" >&2
  exit 1
fi

git -C "$PUBLIC_DIR" push origin main
echo "Pushed public snapshot of $SHORT_SHA to $PUBLIC_ORIGIN"
