# Restore minimized windows on app activation

Opt-in behavior: when you Command-Tab to a regular app with minimized windows and no visible standard window, Glancebar unminimizes one window and leaves the rest minimized. It selects the first minimized window reported by macOS. It does not launch apps, explicitly move Spaces, or restore more than one window. Activating an app with a visible standard window leaves its minimized windows alone.

## Enable

Settings → Restore minimized windows, or:

```bash
defaults write com.iantodd.glancebar restoreMinimizedOnActivate -bool YES
```

Relaunch Glancebar after changing defaults from the shell. Accessibility must already be granted (same permission fine volume uses).

## Debug logging

When diagnosing a no-op restore (for example Finder staying minimized), enable NSLog traces (bundle IDs, window counts, AX error codes only — no titles):

```bash
defaults write com.iantodd.glancebar windowRestoreDebug -bool YES
```

Relaunch Glancebar, reproduce the activation, then inspect Console or `log stream` filtered on `[Glancebar window-restore]`. Turn off with `-bool NO` when finished.

## Verify (manual)

1. Open TextEdit, minimize its window, leave no other TextEdit windows visible.
2. Switch away, then Command-Tab back to TextEdit.
3. One TextEdit window should return; a second minimized window (if you made one) stays in the Dock.
4. Switch apps quickly a few times: focus should not jump to the wrong app.
5. Turn the Settings item off and repeat: minimized windows stay minimized.

## Regression tests

```bash
./tests.sh   # includes test_window_restore; full suite is for remote-run when heavy
```

Or only the policy harness:

```bash
cc -fobjc-arc -Wall -Wextra -Werror -DGLANCEBAR_WINDOW_RESTORE_TEST -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -mmacosx-version-min=13.0 -ISources Sources/window_restore.m Tests/test_window_restore.m \
  -framework Cocoa -o /tmp/glancebar_window_restore_tests && /tmp/glancebar_window_restore_tests
```
## Implementation limits

Restoration follows any app activation (including Command-Tab and Dock activation), not individual keystrokes. AX calls run on a serial background queue with a 150 ms per-call timeout, a bounded window scan, and up to two delayed retries when an app has not exposed its windows yet. The activation generation and foreground app are rechecked before unminimizing. Disabling the feature invalidates pending work. No screenshots, window titles, keyboard hooks, network calls, or additional processes are involved.

If an app does not expose standard windows to Accessibility, it is left alone. A visible standard window on another Space also prevents restoration; this feature does not try to rearrange Spaces.

The window scan skips non-window roles and entries without usable attributes instead of aborting the whole list. A positive minimized attribute makes an AXWindow eligible even if Finder has changed its subrole. Visible auxiliary windows remain ignored, and a visible standard window still prevents restoration. A standard window without a minimized attribute is not treated as visible.
