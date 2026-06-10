# Glancebar

**One configurable macOS menu bar item for machine and AI status — at a glance.**

![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)
![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen.svg)

<p align="center">
  <img src="docs/screenshot.png" alt="Glancebar menu bar item and its combined storage, battery, system, and AI status popover" width="380">
</p>

## Overview

Glancebar shows selected glance metrics in one compact menu bar item (`💾 61%  🔋 76%` by
default). Click it for one native popover with **Storage**, **Battery**, **System**, and
**AI Status** summaries: volume gauges, time until 20%, leading battery/system signals,
and Claude/Codex limit status. A
**Details…** window keeps fuller battery, system, and AI lists behind tabs without
crowding the popover. One item, one slot, **no dependencies, no background services, and
no admin rights**.

It merges two earlier single-purpose apps — [Diskbar](https://github.com/todd866/diskbar)
and Voltbar (battery) — into one, so they stop competing for space next to the notch.

## Key Results

- **Configurable glance** — choose which menu-bar segments appear: storage, battery,
  system, and/or AI status.
- **Storage** — every volume (internal + external/NTFS) with Finder-accurate free space
  (purgeable counts as free); gauges turn orange past 85%, red past 95%.
- **Battery** — "3:14 until 20%" (not a bare percentage), plus battery pressure grouped by
  app/process with raw process names and plain-English context, live draw in watts, and
  battery health / cycle count.
- **System** — overall CPU, memory pressure, swap usage, and top CPU/memory apps grouped
  with the same raw-process-plus-context treatment; the popover shows the lead signals
  while Details keeps the longer lists.
- **AI status** — Claude/Codex remaining percentage and reset time when a local status
  source provides them; historical local usage stays in Details.
- **Self-contained** — one binary, native popover UI, no runtime, no installer, no `sudo`.

## Build & Install

```bash
./build.sh                                  # → build/Glancebar.app (clang, ad-hoc signed)
./tests.sh                                  # run the pure-logic unit tests
cp -R build/Glancebar.app /Applications/    # install
open /Applications/Glancebar.app            # run
```

Start at login: **System Settings → General → Login Items → +** and add Glancebar.
Requires the Xcode Command Line Tools (`xcode-select --install`).

Headless readout: `Glancebar.app/Contents/MacOS/Glancebar --dump` prints disk, battery,
battery pressure, system pressure, and AI status to the terminal.

## How It Works

- **Disk** — `mountedVolumeURLs` (hidden volumes skipped), preferring the Finder-style
  "important usage" free-space figure.
- **Battery** — the IORegistry `AppleSmartBattery` entry (charge, charging state, raw mAh
  capacity, amperage, voltage, cycle count, smoothed time-to-empty). The menu bar updates
  instantly on plug/unplug via an `IOPSNotification`, otherwise every 15s.
- **Time until 20%** — macOS's smoothed minutes-to-empty scaled by `(charge − 20)/charge`,
  with an amperage-based fallback.
- **Battery pressure** — `top -l 2 -stats pid,command,power`, reading the second sample,
  grouped under the **outermost `.app` bundle in each executable path** where possible so
  helpers roll up under their parent app. Rows show the share of sampled app/process
  pressure, while preserving raw process names such as `syspolicyd`.
- **System pressure** — CPU is calculated from Mach processor tick deltas; memory uses
  Mach VM statistics plus `hw.memsize`; swap uses `vm.swapusage`. Top CPU and top memory
  apps come from `ps -axo pid=,pcpu=,rss=,comm=` and are grouped under parent apps where
  possible. If CPU and memory cannot be sampled, Glancebar reports the system state as
  unknown rather than treating missing data as low pressure.
- **AI status** — Glancebar can read exact remaining/reset status from
  `~/.glancebar/ai-status.json`, for example:

  ```json
  {
    "Claude": { "remainingPercent": 42, "resetAt": "2026-06-10T19:00:00+10:00" },
    "Codex": { "remainingPercent": 67, "resetText": "Reset 8:15 PM" }
  }
  ```

  Without that file, limit status is shown as unavailable because the local Claude and
  Codex history caches do not expose quota remaining or reset time. Historical Claude
  usage is still read from `~/.claude/stats-cache.json`, and historical Codex usage from
  aggregate fields in `~/.codex/state_5.sqlite`, for the Details tab only. Glancebar does
  not read auth files or send network requests.

The time estimator, battery-pressure grouping, and process-stat grouping are pure functions
with unit tests (`./tests.sh`); the IORegistry, disk, `top`, `ps`, and local AI state
plumbing live in the app shell.

## Repository

```
glancebar/
├── Sources/pure.{h,m}   # pure, testable logic: time-to-20% + process grouping
├── Sources/main.m       # app shell: disk + battery readers, top sampling, popover UI
├── Tests/test_pure.m    # unit tests for the pure functions
├── tools/mockup.m       # renders docs/screenshot.png
├── build.sh  ·  tests.sh  ·  Info.plist
└── docs/screenshot.png
```

### A note on notched Macs

macOS adds new menu bar items at the left end of the status area, so on a notched MacBook
a fresh icon can land under the notch and look invisible. Free up space (System Settings →
Control Center → set icons you don't need to "Don't Show in Menu Bar") and it appears.
Glancebar being a single item — rather than two — makes this far less likely.

## Related

- **[Diskbar](https://github.com/todd866/diskbar)** — the disk-only predecessor, merged
  into Glancebar. (A battery-only predecessor, Voltbar, was also merged in.)

## Credits

Designed and built by **Claude Fable 5** (Anthropic), working from Ian Todd's brief and
direction — design, implementation, tests, the rendered screenshot, and this README.

## License

MIT — see [LICENSE](LICENSE).
