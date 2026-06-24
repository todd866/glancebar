#!/bin/zsh
# Build Glancebar.app from the Objective-C sources. No Xcode project needed.
set -e
cd "$(dirname "$0")"

APP=build/Glancebar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

clang -fobjc-arc -O2 -mmacosx-version-min=13.0 Sources/pure.m Sources/main.m \
    -framework Cocoa -framework IOKit -framework Security \
    -o "$APP/Contents/MacOS/Glancebar"
cp Info.plist "$APP/Contents/Info.plist"

# Sign with a stable identity so the Keychain grant for the Claude Code-credentials item
# survives rebuilds (ad-hoc signing changes the code hash every build, re-triggering the
# prompt). See README.
#
# Resolution order:
#   1. $GLANCEBAR_CODESIGN_IDENTITY — explicit override; fails loudly if not installed.
#   2. An installed "Developer ID Application" identity (auto-detected). A Developer ID
#      carries a Team ID, which lets the Keychain grant occupy a durable "teamid:"
#      partition — the only thing that makes the Claude account read prompt-free. This is
#      preferred automatically so a plain ./build.sh stays prompt-free once you have one.
#   3. The "Glancebar Self-Signed" cert, matched by SHA-1 (not display name) so a
#      regenerated same-named cert can't silently change the signature. On another machine,
#      create the cert (see README) and pass its hash via GLANCEBAR_CODESIGN_SHA1
#      (`security find-certificate -c "Glancebar Self-Signed" -Z`). A self-signed (no Team
#      ID) build is stable across rebuilds but still re-prompts on every Keychain read.
#   4. Ad-hoc "-" — builds a working app, but the grant re-prompts every build (loud warning).
SELF_SIGNED_SHA1="${GLANCEBAR_CODESIGN_SHA1:-A14E62A164EEEC5A633BFF74C2CA5409A1C4F9E7}"
DEVELOPER_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | sed -E 's/^[^"]*"([^"]+)".*/\1/')
if [[ -n "${GLANCEBAR_CODESIGN_IDENTITY:-}" ]]; then
    IDENTITY="$GLANCEBAR_CODESIGN_IDENTITY"
    if ! security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
        echo "build.sh: ERROR — GLANCEBAR_CODESIGN_IDENTITY '$IDENTITY' is not an available code-signing identity." >&2
        exit 1
    fi
elif [[ -n "$DEVELOPER_ID" ]]; then
    IDENTITY="$DEVELOPER_ID"
elif security find-identity -p codesigning 2>/dev/null | grep -qi "$SELF_SIGNED_SHA1"; then
    IDENTITY="$SELF_SIGNED_SHA1"   # codesign accepts the cert SHA-1 as the identity selector
else
    IDENTITY="-"
    echo "build.sh: WARNING — no stable signing identity found (no Developer ID, no cert" >&2
    echo "  SHA-1 $SELF_SIGNED_SHA1, no \$GLANCEBAR_CODESIGN_IDENTITY). Falling back to AD-HOC" >&2
    echo "  signing: the macOS Keychain 'Always Allow' grant for the Claude Code-credentials" >&2
    echo "  item will re-prompt on every rebuild. See README." >&2
fi
echo "Signing identity: $IDENTITY"
codesign --force --sign "$IDENTITY" "$APP"

echo "Built $APP"
echo "Run:     open $APP"
echo "Install: cp -R $APP /Applications/"
