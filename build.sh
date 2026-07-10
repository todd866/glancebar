#!/bin/zsh
# Build Glancebar.app from the Objective-C sources. No Xcode project needed.
set -euo pipefail
cd "${0:A:h}"

CC="${CC:-$(xcrun --find clang)}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
BUILD_DIR="build"
OUTPUT_APP="$BUILD_DIR/Glancebar.app"
mkdir -p "$BUILD_DIR"
STAGING_DIR="$(mktemp -d "$BUILD_DIR/.glancebar-build.XXXXXX")"
APP="$STAGING_DIR/Glancebar.app"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A build is publishable only if its tests pass first.
./tests.sh
plutil -lint Info.plist >/dev/null

# Universal 2 is the default. On a toolchain without cross-architecture support, use
# GLANCEBAR_ARCHS=native. An explicit subset such as "arm64" is also accepted.
ARCH_FLAGS=()
ARCH_DESCRIPTION="native"
ARCHS_VALUE="${GLANCEBAR_ARCHS:-arm64 x86_64}"
if [[ "$ARCHS_VALUE" != "native" ]]; then
    ARCHS=("${(@z)ARCHS_VALUE}")
    if (( ${#ARCHS[@]} == 0 )); then
        echo "build.sh: ERROR — GLANCEBAR_ARCHS must be 'native' or a space-separated architecture list." >&2
        exit 1
    fi
    for ARCH in "${ARCHS[@]}"; do
        case "$ARCH" in
            arm64|x86_64) ARCH_FLAGS+=(-arch "$ARCH") ;;
            *)
                echo "build.sh: ERROR — unsupported architecture '$ARCH' (expected arm64 or x86_64)." >&2
                exit 1
                ;;
        esac
    done
    ARCH_DESCRIPTION="${(j: :)ARCHS}"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"$CC" \
    -fobjc-arc \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    -isysroot "$SDKROOT" \
    -mmacosx-version-min=13.0 \
    "${ARCH_FLAGS[@]}" \
    Sources/pure.m Sources/main.m \
    -framework Cocoa \
    -framework IOKit \
    -framework ServiceManagement \
    -o "$APP/Contents/MacOS/Glancebar"
install -m 0644 Info.plist "$APP/Contents/Info.plist"
install -m 0644 Resources/Glancebar.icns "$APP/Contents/Resources/Glancebar.icns"

# Sign with a stable identity. Ad-hoc signing changes the code hash on every build, which
# invalidates the Keychain grant for the Claude Code credential and leaves SMAppService
# without the durable code identity Launch at Login registers against.
#
# Resolution order:
#   1. $GLANCEBAR_CODESIGN_IDENTITY — explicit override; fails loudly if not installed.
#   2. GLANCEBAR_ADHOC=1 — deliberate ad-hoc, for CI and reproducible builds.
#   3. An installed "Developer ID Application" identity. It carries a Team ID, which lets the
#      Keychain grant occupy a durable "teamid:" partition — the only thing that makes the
#      Claude account read prompt-free. Preferred automatically so a plain ./build.sh stays
#      prompt-free once you have one. Set GLANCEBAR_ADHOC=1 on a shared machine.
#   4. The "Glancebar Self-Signed" cert, matched by SHA-1 rather than display name so a
#      regenerated same-named cert cannot silently change the signature.
#   5. Ad-hoc "-", with a loud warning.
SELF_SIGNED_SHA1="${GLANCEBAR_CODESIGN_SHA1:-A14E62A164EEEC5A633BFF74C2CA5409A1C4F9E7}"
# `|| true`: under `set -o pipefail` the grep exits 1 when no Developer ID is installed, which
# would abort the build before it could fall back to ad-hoc. That is the CI path.
DEVELOPER_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 "Developer ID Application" | sed -E 's/^[^"]*"([^"]+)".*/\1/' || true)
if [[ -n "${GLANCEBAR_CODESIGN_IDENTITY:-}" ]]; then
    IDENTITY="$GLANCEBAR_CODESIGN_IDENTITY"
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
        echo "build.sh: ERROR — GLANCEBAR_CODESIGN_IDENTITY '$IDENTITY' is not available." >&2
        exit 1
    fi
elif [[ "${GLANCEBAR_ADHOC:-0}" == "1" ]]; then
    IDENTITY="-"
    echo "Signing: ad-hoc (GLANCEBAR_ADHOC=1)"
elif [[ -n "$DEVELOPER_ID" ]]; then
    IDENTITY="$DEVELOPER_ID"
elif security find-identity -v -p codesigning 2>/dev/null | grep -qi "$SELF_SIGNED_SHA1"; then
    IDENTITY="$SELF_SIGNED_SHA1"   # codesign accepts the cert SHA-1 as the identity selector
else
    IDENTITY="-"
    echo "build.sh: WARNING — no stable signing identity found (no Developer ID, no cert" >&2
    echo "  SHA-1 $SELF_SIGNED_SHA1, no \$GLANCEBAR_CODESIGN_IDENTITY). Falling back to AD-HOC" >&2
    echo "  signing: the Keychain grant for the Claude Code credential re-prompts on every" >&2
    echo "  rebuild, and Launch at Login may need re-approval. See docs/RELEASING.md." >&2
fi

CODESIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "${GLANCEBAR_HARDENED_RUNTIME:-1}" == "1" ]]; then
    CODESIGN_ARGS+=(--options runtime)
elif [[ "${GLANCEBAR_HARDENED_RUNTIME:-1}" != "0" ]]; then
    echo "build.sh: ERROR — GLANCEBAR_HARDENED_RUNTIME must be 0 or 1." >&2
    exit 1
fi

if [[ "${GLANCEBAR_TIMESTAMP:-0}" == "1" ]]; then
    if [[ "$IDENTITY" == "-" ]]; then
        echo "build.sh: ERROR — timestamping requires an explicit signing identity." >&2
        exit 1
    fi
    CODESIGN_ARGS+=(--timestamp)
elif [[ "${GLANCEBAR_TIMESTAMP:-0}" != "0" ]]; then
    echo "build.sh: ERROR — GLANCEBAR_TIMESTAMP must be 0 or 1." >&2
    exit 1
fi

echo "Architectures: $ARCH_DESCRIPTION"
echo "Signing identity: $IDENTITY"
codesign "${CODESIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -rf "$OUTPUT_APP"
mv "$APP" "$OUTPUT_APP"

echo "Built $OUTPUT_APP"
echo "Run:     open $OUTPUT_APP"
echo "Install: cp -R $OUTPUT_APP /Applications/"
