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

# Signing is intentionally deterministic: use the exact identity supplied by the
# builder, or ad-hoc signing for a local build. Never borrow an unrelated identity.
IDENTITY="${GLANCEBAR_CODESIGN_IDENTITY:--}"
if [[ "$IDENTITY" != "-" ]]; then
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
        echo "build.sh: ERROR — GLANCEBAR_CODESIGN_IDENTITY '$IDENTITY' is not available." >&2
        exit 1
    fi
else
    echo "Signing: ad-hoc (set GLANCEBAR_CODESIGN_IDENTITY for a distributable build)"
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
