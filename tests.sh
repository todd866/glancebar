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

"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Tests/test_battery_forecast.m \
    -framework Foundation -o "$WORK_DIR/glancebar_battery_tests"
"$WORK_DIR/glancebar_battery_tests"

"$CC" "${TEST_FLAGS[@]}" Sources/activity.m Tests/test_activity.m -framework Foundation -o "$WORK_DIR/glancebar_activity_tests"
"$WORK_DIR/glancebar_activity_tests"

# Stateful filesystem/incremental-reader coverage. The harness imports the private app
# shell so it exercises the production AIReader without publishing a test-only API.
"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Sources/activity.m Sources/nowplaying.m Tests/test_ai_reader.m \
    -framework Cocoa \
    -framework AVFoundation -framework CoreMedia -framework MediaPlayer -framework Network -framework SystemConfiguration \
    -framework CoreAudio \
    -framework IOKit \
    -framework ServiceManagement -framework Security -lsqlite3 \
    -o "$WORK_DIR/glancebar_ai_reader_tests"

"$WORK_DIR/glancebar_ai_reader_tests"

# Metered-link transport and persistence coverage. The harness imports the private monitor
# but stubs both interface counters and NSURLSession-facing tick paths.
"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Sources/activity.m Sources/nowplaying.m Tests/test_metered.m \
    -framework Cocoa -framework AVFoundation -framework CoreMedia -framework MediaPlayer -framework Network -framework SystemConfiguration \
    -framework CoreAudio -framework IOKit -framework ServiceManagement -framework Security -lsqlite3 \
    -o "$WORK_DIR/glancebar_metered_tests"
"$WORK_DIR/glancebar_metered_tests"

"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Sources/activity.m Sources/nowplaying.m Tests/test_activity_ui.m \
    -framework Cocoa -framework AVFoundation -framework CoreMedia -framework MediaPlayer -framework Network -framework SystemConfiguration \
    -framework CoreAudio -framework IOKit -framework ServiceManagement -framework Security -lsqlite3 \
    -o "$WORK_DIR/glancebar_activity_ui_tests"
"$WORK_DIR/glancebar_activity_ui_tests"
if [[ -n "${GLANCEBAR_ACTIVITY_HARNESS_OUT:-}" ]]; then
    cp "$WORK_DIR/glancebar_activity_ui_tests" "$GLANCEBAR_ACTIVITY_HARNESS_OUT"
fi

# Production AppKit layout, rendered without creating any visible windows.
"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Sources/activity.m Sources/nowplaying.m tools/check-popover.m \
    -framework Cocoa -framework AVFoundation -framework CoreMedia -framework MediaPlayer -framework Network -framework SystemConfiguration \
    -framework CoreAudio -framework IOKit -framework ServiceManagement -framework Security -lsqlite3 \
    -o "$WORK_DIR/glancebar_popover_tests"
"$WORK_DIR/glancebar_popover_tests"
if [[ -n "${GLANCEBAR_POPOVER_HARNESS_OUT:-}" ]]; then
    cp "$WORK_DIR/glancebar_popover_tests" "$GLANCEBAR_POPOVER_HARNESS_OUT"
fi
