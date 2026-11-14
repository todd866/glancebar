#!/bin/zsh
# Compile and run Glancebar's unit/regression and incremental-reader integration tests.
set -euo pipefail
cd "${0:A:h}"

/usr/bin/python3 -m unittest discover -s tools/offline-cache -v
/usr/bin/python3 -m unittest discover -s tools/music-library -v
/usr/bin/python3 -m unittest discover -s tools/music-scout -v
/usr/bin/python3 -m unittest discover -s tools/music-sync -v
/usr/bin/python3 -m unittest discover -s tools/media-sync -v

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

"$CC" "${TEST_FLAGS[@]}" Sources/storage_scan.m Sources/storage_cleanup.m Tests/test_storage.m -framework Foundation -o "$WORK_DIR/glancebar_storage_tests"
"$WORK_DIR/glancebar_storage_tests"

"$CC" "${TEST_FLAGS[@]}" Sources/storage_scan.m Sources/storage_cleanup.m Sources/storage_index.m Tests/test_storage_index.m -framework Foundation -o "$WORK_DIR/glancebar_storage_index_tests"
"$WORK_DIR/glancebar_storage_index_tests"

"$CC" "${TEST_FLAGS[@]}" Sources/volume_step.m Tests/test_volume_step.m -framework Foundation -o "$WORK_DIR/glancebar_volume_step_tests"
"$WORK_DIR/glancebar_volume_step_tests"

"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Tests/test_player_output.m -framework Foundation -o "$WORK_DIR/glancebar_player_output_tests"
"$WORK_DIR/glancebar_player_output_tests"

# Stateful filesystem/incremental-reader coverage. The harness imports the private app
# shell so it exercises the production AIReader without publishing a test-only API.
"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Sources/activity.m Sources/storage_scan.m Sources/storage_cleanup.m Sources/storage_index.m Sources/nowplaying.m Sources/volume_step.m Sources/fine_volume.m Tests/test_ai_reader.m \
    -framework Cocoa -framework Carbon \
    -framework AVFoundation -framework CoreMedia -framework MediaPlayer -framework Network -framework SystemConfiguration \
    -framework CoreAudio -framework AudioToolbox \
    -framework IOKit \
    -framework DiskArbitration \
    -framework ServiceManagement -framework Security -lsqlite3 \
    -o "$WORK_DIR/glancebar_ai_reader_tests"

"$WORK_DIR/glancebar_ai_reader_tests"

# Exact offline requests, no partial playback and intercepted source/player boundaries.
"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Sources/activity.m Sources/storage_scan.m Sources/storage_cleanup.m Sources/storage_index.m Sources/nowplaying.m Sources/volume_step.m Sources/fine_volume.m Tests/test_offline.m \
    -framework Cocoa -framework Carbon -framework AVFoundation -framework CoreMedia -framework MediaPlayer -framework Network -framework SystemConfiguration \
    -framework CoreAudio -framework AudioToolbox -framework IOKit -framework DiskArbitration -framework ServiceManagement -framework Security -lsqlite3 \
    -o "$WORK_DIR/glancebar_offline_tests"
"$WORK_DIR/glancebar_offline_tests"

# Music-library sync storm regression (intercepted helpers, no subprocess I/O).
"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Sources/activity.m Sources/storage_scan.m Sources/storage_cleanup.m Sources/storage_index.m Sources/nowplaying.m Sources/volume_step.m Sources/fine_volume.m Tests/test_music_library_storm.m \
    -framework Cocoa -framework Carbon -framework AVFoundation -framework CoreMedia -framework MediaPlayer -framework Network -framework SystemConfiguration \
    -framework CoreAudio -framework AudioToolbox -framework IOKit -framework DiskArbitration -framework ServiceManagement -framework Security -lsqlite3 \
    -o "$WORK_DIR/glancebar_music_library_storm_tests"
"$WORK_DIR/glancebar_music_library_storm_tests"

# Metered-link transport and persistence coverage. The harness imports the private monitor
# but stubs both interface counters and NSURLSession-facing tick paths.
"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Sources/activity.m Sources/storage_scan.m Sources/storage_cleanup.m Sources/storage_index.m Sources/nowplaying.m Sources/volume_step.m Sources/fine_volume.m Tests/test_metered.m \
    -framework Cocoa -framework Carbon -framework AVFoundation -framework CoreMedia -framework MediaPlayer -framework Network -framework SystemConfiguration \
    -framework CoreAudio -framework AudioToolbox -framework IOKit -framework DiskArbitration -framework ServiceManagement -framework Security -lsqlite3 \
    -o "$WORK_DIR/glancebar_metered_tests"
"$WORK_DIR/glancebar_metered_tests"

"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Sources/activity.m Sources/storage_scan.m Sources/storage_cleanup.m Sources/storage_index.m Sources/nowplaying.m Sources/volume_step.m Sources/fine_volume.m Tests/test_activity_ui.m \
    -framework Cocoa -framework Carbon -framework AVFoundation -framework CoreMedia -framework MediaPlayer -framework Network -framework SystemConfiguration \
    -framework CoreAudio -framework AudioToolbox -framework IOKit -framework DiskArbitration -framework ServiceManagement -framework Security -lsqlite3 \
    -o "$WORK_DIR/glancebar_activity_ui_tests"
"$WORK_DIR/glancebar_activity_ui_tests"
if [[ -n "${GLANCEBAR_ACTIVITY_HARNESS_OUT:-}" ]]; then
    cp "$WORK_DIR/glancebar_activity_ui_tests" "$GLANCEBAR_ACTIVITY_HARNESS_OUT"
fi

"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Sources/activity.m Sources/storage_scan.m Sources/storage_cleanup.m Sources/storage_index.m Sources/nowplaying.m Sources/volume_step.m Sources/fine_volume.m Tests/test_storage_ui.m \
    -framework Cocoa -framework Carbon -framework AVFoundation -framework CoreMedia -framework MediaPlayer -framework Network -framework SystemConfiguration \
    -framework CoreAudio -framework AudioToolbox -framework IOKit -framework DiskArbitration -framework ServiceManagement -framework Security -lsqlite3 \
    -o "$WORK_DIR/glancebar_storage_ui_tests"
"$WORK_DIR/glancebar_storage_ui_tests"
if [[ -n "${GLANCEBAR_STORAGE_HARNESS_OUT:-}" ]]; then
    cp "$WORK_DIR/glancebar_storage_ui_tests" "$GLANCEBAR_STORAGE_HARNESS_OUT"
fi

# Production AppKit layout, rendered without creating any visible windows.
"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Sources/activity.m Sources/storage_scan.m Sources/storage_cleanup.m Sources/storage_index.m Sources/nowplaying.m Sources/volume_step.m Sources/fine_volume.m tools/check-popover.m \
    -framework Cocoa -framework Carbon -framework AVFoundation -framework CoreMedia -framework MediaPlayer -framework Network -framework SystemConfiguration \
    -framework CoreAudio -framework AudioToolbox -framework IOKit -framework DiskArbitration -framework ServiceManagement -framework Security -lsqlite3 \
    -o "$WORK_DIR/glancebar_popover_tests"
"$WORK_DIR/glancebar_popover_tests"
GLANCEBAR_MUSIC_STATE=playing "$WORK_DIR/glancebar_popover_tests"
GLANCEBAR_MUSIC_STATE=idle "$WORK_DIR/glancebar_popover_tests"
if [[ -n "${GLANCEBAR_POPOVER_HARNESS_OUT:-}" ]]; then
    cp "$WORK_DIR/glancebar_popover_tests" "$GLANCEBAR_POPOVER_HARNESS_OUT"
fi

# Real AVQueuePlayer playback in silent QA (isolated home, no app launch).
"$CC" "${TEST_FLAGS[@]}" Sources/pure.m Sources/activity.m Sources/storage_scan.m Sources/storage_cleanup.m Sources/storage_index.m Sources/nowplaying.m Sources/volume_step.m Sources/fine_volume.m tools/check-playback.m \
    -framework Cocoa -framework Carbon -framework AVFoundation -framework CoreMedia -framework MediaPlayer -framework Network -framework SystemConfiguration \
    -framework CoreAudio -framework AudioToolbox -framework IOKit -framework DiskArbitration -framework ServiceManagement -framework Security -lsqlite3 \
    -o "$WORK_DIR/glancebar_playback_tests"
/usr/bin/python3 -c "
import subprocess, sys
try:
    sys.exit(subprocess.run([sys.argv[1]], timeout=120).returncode)
except subprocess.TimeoutExpired:
    print('Playback harness timed out after 120s', file=sys.stderr)
    sys.exit(124)
" "$WORK_DIR/glancebar_playback_tests"
