#!/bin/zsh
# Compile and run Glancebar's unit/regression and incremental-reader integration tests.
set -euo pipefail
cd "${0:A:h}"

CC="${CC:-$(xcrun --find clang)}"
SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
TMP_ROOT="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "$TMP_ROOT/glancebar-tests.XXXXXX")"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

TEST_FLAGS=(
    -fobjc-arc
    -Wall
    -Wextra
    -Werror
    -isysroot
    "$SDKROOT"
    -mmacosx-version-min=13.0
    -ISources
)

if [[ "${GLANCEBAR_TEST_SANITIZERS:-0}" == "1" ]]; then
    TEST_FLAGS+=(
        -O1
        -g
        -fsanitize=address,undefined
        -fno-omit-frame-pointer
    )
fi

"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Tests/test_pure.m \
    -framework Foundation \
    -o "$WORK_DIR/glancebar_tests"

"$WORK_DIR/glancebar_tests"

# Stateful filesystem/incremental-reader coverage. The harness imports the private app
# shell so it exercises the production AIReader without publishing a test-only API.
"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Tests/test_ai_reader.m \
    -framework Cocoa \
    -framework IOKit \
    -framework ServiceManagement \
    -o "$WORK_DIR/glancebar_ai_reader_tests"

"$WORK_DIR/glancebar_ai_reader_tests"
