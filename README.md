# Glancebar

**One configurable macOS menu bar item for machine and AI status — at a glance.**

![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)
![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen.svg)

<p align="center">
  <img src="docs/screenshot.png?v=7c524a2" alt="Glancebar menu bar item and its combined storage, battery, system, and AI status popover" width="380">
</p>

## Overview

Glancebar puts the numbers that ruin your day in one compact menu bar item
(`💾 61%  🔋 76%` by default). Click it for a single native popover with **Storage**,
**Battery**, **System**, and **AI Status** summaries: volume gauges, time until 20%,
the leading battery/system culprits in plain English, and Claude/Codex limit gauges.
A **Details…** window keeps the fuller lists behind tabs without crowding the popover.

One item, one slot, **no dependencies, no daemons or helpers — everything runs inside
the one app you can quit — and no admin rights**.

## Features

- **Storage** — every volume (internal + external/NTFS) with Finder-accurate free space
  (purgeable counts as free); gauges turn orange past 85%, red past 95%.
- **Battery** — "3:14 until 20%" (not a bare percentage), battery pressure grouped by
  app/process with raw process names and plain-English context, live draw in watts, and
  battery health / cycle count.
- **System** — overall CPU, memory pressure (the kernel's own verdict, not a heuristic),
  swap, and top CPU/memory apps with the same raw-process-plus-context treatment; the
  popover shows the lead signals, Details keeps the longer lists.
- **AI status** — Codex's official remaining-quota percentage and reset time from its
  own session logs; an opt-in gauge for your Claude account; live per-day token totals
  for both, counted the way a human would (cached context re-reads shown separately).
- **Configurable glance** — choose which menu-bar segments appear: storage, battery,
  system, and/or AI status.
- **Self-contained** — one binary, native AppKit, no runtime, no installer, no `sudo`,
  no network requests unless you opt in.

## Build & Install

```bash
./build.sh                                  # → build/Glancebar.app (clang; stable identity if present, else ad-hoc)
./tests.sh                                  # run the pure-logic unit tests
cp -R build/Glancebar.app /Applications/    # install
open /Applications/Glancebar.app            # run
```

Start at login: **System Settings → General → Login Items → +** and add Glancebar.
Requires the Xcode Command Line Tools (`xcode-select --install`).

There are no prebuilt or notarized downloads — build locally with `./build.sh`. A
locally built app carries no quarantine flag, so it opens without a Gatekeeper prompt.
If you copy a built `.app` from another machine, clear the quarantine flag first:
`xattr -dr com.apple.quarantine /Applications/Glancebar.app`.

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
  pressure, while preserving raw process names such as `syspolicyd`. Process sampling
  runs only while the popover or Details window is open.
- **System pressure** — CPU from Mach processor tick deltas; memory pressure from
  `kern.memorystatus_vm_pressure_level` (the kernel's own verdict); swap from
  `vm.swapusage`. Top CPU/memory apps come from `ps`, normalized to the all-cores scale
  and measured by physical footprint (what Activity Monitor shows), grouped under parent
  apps where possible.
- **AI status** — Codex's limit gauge comes straight from its own session logs: each
  turn in `~/.codex/sessions/**.jsonl` (and rotated
  `~/.codex/archived_sessions/**.jsonl`) records OpenAI's official rate-limit state
  (`used_percent` and reset time for the 5-hour and weekly windows), and Glancebar shows
  the most constrained window that is still current. The same per-turn records carry
  exact token deltas, which is how today/7-day totals are computed. Headline counts are
  **fresh tokens** (non-cached input + output); the raw total is ~16× larger because
  cached context is re-read every turn, and is shown alongside. If enabled, Claude's
  token counts come the same way — live from the per-message usage records in
  `~/.claude/projects/**.jsonl` transcripts. JSONL files are append-only and read
  incrementally by byte offset on a background queue, with per-tick read limits.

  Claude's *quota* gauge has no on-disk source (Claude Code fetches it from the API at
  display time), so it fills in one of two ways. The options menu has an **opt-in**
  "Claude account via Keychain/API" toggle (off by default): it reads the OAuth token
  Claude Code already maintains in your Keychain (macOS asks for permission) and polls
  Anthropic's usage endpoint — the same data Claude Code's `/usage` shows — at most
  every 15 minutes. The token is cached in memory only until expiry, never written by
  Glancebar, never refreshed by Glancebar, and never sent anywhere except
  `api.anthropic.com`. If the account response reports paid overage usage at or above
  100%, Glancebar shows that as an explicit red 0% status instead of a missing gauge.
  Or provide `~/.glancebar/ai-status.json`, which overrides either provider's gauge:

  ```json
  {
    "Claude": { "remainingPercent": 42, "resetAt": "2026-06-10T19:00:00+10:00" }
  }
  ```

  Claude transcript token totals are a separate **opt-in** toggle because transcript
  JSONL files contain conversation records even though Glancebar only extracts usage
  counters. With both Claude toggles off, Glancebar reads local aggregate state only —
  never Claude auth files or transcripts — and sends no network requests.

  `--dump` is local-only by default. To allow account-backed Claude status in a dump,
  pass `--online` or set `GLANCEBAR_ALLOW_ACCOUNT=1`.

  **Signing & the password prompt.** macOS Keychain grants are tied to the app's
  *signing requirement* and, on the modern login keychain, to a per-item *partition
  list*. `./build.sh` signs with a stable identity so the requirement doesn't change
  between rebuilds: it prefers `$GLANCEBAR_CODESIGN_IDENTITY` (e.g. a Developer ID), else
  the `Glancebar Self-Signed` cert matched by **SHA-1** (create one in **Keychain Access →
  Certificate Assistant → Create a Certificate**: Name `Glancebar Self-Signed`, Self
  Signed Root, Code Signing — then pass its hash via `GLANCEBAR_CODESIGN_SHA1` on other
  machines), else ad-hoc with a loud warning (ad-hoc changes the code hash every build, so
  the grant re-prompts).

  A stable signature is necessary but **not sufficient** for the Claude account toggle.
  The `Claude Code-credentials` item's partition list only admits Apple's own tools and
  apps with a matching **Team ID**. A *self-signed, no-Team-ID* Glancebar is already a
  trusted application on the item yet still gets the password prompt on every read because
  it can't satisfy the partition — and "Allow all applications" / "Always Allow" do **not**
  durably clear it. The durable fix is to sign with a **Developer ID** (which carries a
  Team ID): `GLANCEBAR_CODESIGN_IDENTITY="Developer ID Application: <name> (<TEAMID>)" ./build.sh`,
  then grant access once. Otherwise leave the toggle off — the prompt only fires while the
  toggle is on and an AI surface (popover/Details) is open.

The time estimator, battery-pressure grouping, process-stat grouping, and log parsing
are pure functions with unit tests (`./tests.sh`); the IORegistry, disk, `top`, `ps`,
and local AI state plumbing live in the app shell.

## Repository

```
glancebar/
├── Sources/pure.{h,m}   # pure, testable logic: estimators, grouping, log parsing
├── Sources/main.m       # app shell: readers, sampling, popover + details UI
├── Tests/test_pure.m    # unit tests for the pure functions
├── tools/mockup.m       # renders docs/screenshot.png
├── build.sh  ·  tests.sh  ·  Info.plist
└── docs/screenshot.png
```

### A note on notched Macs

macOS adds new menu bar items at the left end of the status area, so on a notched MacBook
a fresh icon can land under the notch and look invisible. Free up space (System Settings →
Control Center → set icons you don't need to "Don't Show in Menu Bar") and it appears.
Glancebar being a single item makes this far less likely.

## Credits

Built by Claude (Anthropic) and Codex (OpenAI), working from Ian Todd's brief and
direction — design, implementation, tests, the rendered screenshot, and this README.

## License

MIT — see [LICENSE](LICENSE).
