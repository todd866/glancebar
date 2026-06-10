# Glancebar

**One macOS menu bar item for disk and battery — at a glance.**

![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)
![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen.svg)

<p align="center">
  <img src="docs/screenshot.png" alt="Glancebar menu bar item and its combined storage + battery popover" width="380">
</p>

## Overview

Glancebar shows your disk usage and battery charge in a single compact menu bar item
(`💾 61%  🔋 76%`). Click it for one native popover with **Storage**, **Battery**, and
**System** summaries: volumes, time until 20%, battery pressure by app/process, CPU,
memory pressure, swap, and the leading CPU/memory culprits. A **Details…** window keeps
fuller battery and system process lists behind tabs without crowding the popover. One
item, one slot, **no dependencies, no background services, and no admin rights**.

It merges two earlier single-purpose apps — [Diskbar](https://github.com/todd866/diskbar)
and Voltbar (battery) — into one, so they stop competing for space next to the notch.

## Key Results

- **Both at a glance** — disk % and battery % share one tidy menu bar item.
- **Storage** — every volume (internal + external/NTFS) with Finder-accurate free space
  (purgeable counts as free); gauges turn orange past 85%, red past 95%.
- **Battery** — "3:14 until 20%" (not a bare percentage), plus battery pressure grouped by
  app/process with raw process names and plain-English context, live draw in watts, and
  battery health / cycle count.
- **System** — overall CPU, memory pressure, swap usage, and top CPU/memory apps grouped
  with the same raw-process-plus-context treatment; the popover shows the lead signals
  while Details keeps the longer lists.
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
battery pressure, and system pressure to the terminal.

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

The time estimator, battery-pressure grouping, and process-stat grouping are pure functions
with unit tests (`./tests.sh`); the IORegistry, disk, `top`, and `ps` plumbing live in the
app shell.

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
