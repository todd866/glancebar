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
(`💾 61%  🔋 76%`). Click it for one native popover with two sections: **Storage**
(every mounted volume with a usage gauge) and **Battery** (time until 20%, the top
energy-using apps, current draw, and health). One item, one slot, **no dependencies, no
background services, and no admin rights**.

It merges two earlier single-purpose apps — [Diskbar](https://github.com/todd866/diskbar)
and Voltbar (battery) — into one, so they stop competing for space next to the notch.

## Key Results

- **Both at a glance** — disk % and battery % share one tidy menu bar item.
- **Storage** — every volume (internal + external/NTFS) with Finder-accurate free space
  (purgeable counts as free); gauges turn orange past 85%, red past 95%.
- **Battery** — "3:14 until 20%" (not a bare percentage), plus energy hogs grouped by app
  the way Activity Monitor does, live draw in watts, and battery health / cycle count.
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
and energy hogs to the terminal.

## How It Works

- **Disk** — `mountedVolumeURLs` (hidden volumes skipped), preferring the Finder-style
  "important usage" free-space figure.
- **Battery** — the IORegistry `AppleSmartBattery` entry (charge, charging state, raw mAh
  capacity, amperage, voltage, cycle count, smoothed time-to-empty). The menu bar updates
  instantly on plug/unplug via an `IOPSNotification`, otherwise every 15s.
- **Time until 20%** — macOS's smoothed minutes-to-empty scaled by `(charge − 20)/charge`,
  with an amperage-based fallback.
- **Energy hogs** — `top -l 2 -stats pid,command,power`, reading the second sample, with
  each process grouped under the **outermost `.app` bundle in its executable path** so
  helpers roll up under their parent app.

The time estimator and energy-grouping are pure functions with unit tests (`./tests.sh`);
the IORegistry, disk, and `top` plumbing live in the app shell.

## Repository

```
glancebar/
├── Sources/pure.{h,m}   # pure, testable logic: time-to-20% + energy grouping
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
