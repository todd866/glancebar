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

# Sign with a stable identity so the Keychain "Always Allow" grant for the Claude
# Code-credentials item survives rebuilds (ad-hoc signing changes the code hash every
# build, which re-triggers the prompt). See README.
#
# Resolution order:
#   1. $GLANCEBAR_CODESIGN_IDENTITY — an explicit identity (e.g. a Developer ID, whose
#      Team ID also lets a durable Keychain "teamid:" partition be granted). If it is
#      set but not an available code-signing identity, the build fails loudly.
#   2. The "Glancebar Self-Signed" cert, matched by SHA-1 (not display name) so a
#      regenerated same-named cert can't silently change the signature and invalidate
#      the grant. On another machine, create the cert (see README) and pass its hash via
#      GLANCEBAR_CODESIGN_SHA1 (`security find-certificate -c "Glancebar Self-Signed" -Z`).
#   3. Ad-hoc "-" — builds a working app, but the Keychain grant re-prompts every build
#      (loud warning, never silent).
SELF_SIGNED_SHA1="${GLANCEBAR_CODESIGN_SHA1:-A14E62A164EEEC5A633BFF74C2CA5409A1C4F9E7}"
if [[ -n "${GLANCEBAR_CODESIGN_IDENTITY:-}" ]]; then
    IDENTITY="$GLANCEBAR_CODESIGN_IDENTITY"
    if ! security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
        echo "build.sh: ERROR — GLANCEBAR_CODESIGN_IDENTITY '$IDENTITY' is not an available code-signing identity." >&2
        exit 1
    fi
elif security find-identity -p codesigning 2>/dev/null | grep -qi "$SELF_SIGNED_SHA1"; then
    IDENTITY="$SELF_SIGNED_SHA1"   # codesign accepts the cert SHA-1 as the identity selector
else
    IDENTITY="-"
    echo "build.sh: WARNING — no stable signing identity found (looked for cert SHA-1" >&2
    echo "  $SELF_SIGNED_SHA1 and \$GLANCEBAR_CODESIGN_IDENTITY). Falling back to AD-HOC" >&2
    echo "  signing: the macOS Keychain 'Always Allow' grant for the Claude Code-credentials" >&2
    echo "  item will re-prompt on every rebuild. Create the 'Glancebar Self-Signed' cert" >&2
    echo "  (see README) and/or set GLANCEBAR_CODESIGN_SHA1." >&2
fi
codesign --force --sign "$IDENTITY" "$APP"

echo "Built $APP"
echo "Run:     open $APP"
echo "Install: cp -R $APP /Applications/"
