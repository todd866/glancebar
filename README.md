# Glancebar

**One configurable macOS menu bar item for machine and AI status — at a glance.**

![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)
![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen.svg)

<p align="center">
  <img src="docs/screenshot.png?v=24ce5cff" alt="Glancebar menu bar item and its combined storage, battery, system, and AI status popover" width="380">
</p>

## Overview

Glancebar puts the numbers that ruin your day in one compact menu bar item
(`💾 61%  🔋 76%` by default). Click it for a single native popover with **Storage**,
**Battery**, **System**, and **AI Status** summaries: volume gauges, time until 20%,
the leading battery/system culprits in plain English, and Claude/Codex limit gauges.
A **Details…** window keeps the fuller lists behind tabs without crowding the popover.

One item, one slot, **no third-party dependencies, bundled daemons, or bundled helper
executables—and no admin rights**. Glancebar does invoke standard macOS tools such as
`top`, `ps`, `sqlite3`, and (only after the Claude account opt-in) `/usr/bin/security`.

## Features

- **Storage** — every volume (internal + external/NTFS) with Finder-accurate free space
  (purgeable counts as free); gauges turn orange past 85%, red past 95%.
- **Battery** — "3:14 until 20%" (not a bare percentage), sampled energy impact grouped
  by app/process with raw process names and plain-English context, live draw in watts,
  and battery health / cycle count.
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
./tests.sh                                  # run unit/regression + reader integration tests
./build.sh                                  # test, build Universal 2, then sign
cp -R build/Glancebar.app /Applications/    # install
open /Applications/Glancebar.app            # run
```

The build uses `-Wall -Wextra -Werror`, the macOS hardened runtime, and both `arm64`
and `x86_64` by default. Set `GLANCEBAR_ARCHS=native` if the local toolchain cannot
cross-compile. Requires the Xcode Command Line Tools (`xcode-select --install`).

Signing prefers, in order: `GLANCEBAR_CODESIGN_IDENTITY`, then an installed
`Developer ID Application` identity, then the `Glancebar Self-Signed` cert, then ad-hoc.
Prefer a stable identity: ad-hoc signing pins the designated requirement to the code hash,
so every rebuild looks like a new program and Launch at Login is re-registered. It does not
affect the Keychain prompt — the Claude Code credential is read through Apple's
`/usr/bin/security`, which is judged against that tool's signature rather than Glancebar's.
Pass `GLANCEBAR_ADHOC=1` to force ad-hoc on a shared machine or in CI.

This repository does not currently advertise a prebuilt or notarized download; build
locally with `./build.sh`. Do not remove quarantine from an app obtained from someone
else unless you have independently verified it. Maintainers can follow
[`docs/RELEASING.md`](docs/RELEASING.md) to create a signed, notarized candidate.

Launch at Login can be enabled during first run or from Glancebar's options. You can
also manage it in **System Settings → General → Login Items**.

The bundled executable also has a stable headless interface:

```bash
build/Glancebar.app/Contents/MacOS/Glancebar --dump                 # human-readable, local only
build/Glancebar.app/Contents/MacOS/Glancebar --dump --json          # schemaVersion 1 JSON
build/Glancebar.app/Contents/MacOS/Glancebar --dump --strict --json # exit 2 if any source is partial
```

`--help` and `--version` are available for scripts. JSON is written by itself to
stdout; unknown options are usage errors. `--online` permits the account request only
when the Claude account integration has already been enabled in Glancebar. In schema
v1, each top-level source (`storage`, `battery`, `sampledEnergyImpact`, `system`, and
`ai`) exposes `available` and `error`; `partialSources` names every unavailable or
incomplete source that makes `--strict` exit 2. An unconfigured Claude account source
is optional; after `--online` explicitly requests an enabled integration, a failed or
stale account refresh is reported as `ai.account` and is strict-partial.

## How It Works

- **Disk** — `mountedVolumeURLs` (hidden volumes skipped), preferring the Finder-style
  "important usage" free-space figure.
- **Battery** — the IORegistry `AppleSmartBattery` entry (charge, charging state, raw mAh
  capacity, amperage, voltage, cycle count, smoothed time-to-empty). The menu bar updates
  instantly on plug/unplug via an `IOPSNotification`, otherwise every 15s.
- **Time until 20%** — macOS's smoothed minutes-to-empty scaled by `(charge − 20)/charge`,
  with an amperage-based fallback.
- **Sampled energy impact** — `top -l 2 -stats pid,command,power`, reading the second sample,
  grouped under the **outermost `.app` bundle in each executable path** where possible so
  helpers roll up under their parent app. Rows show each app/process's relative share of
  the sampled energy-impact values—not a percentage of battery consumed—while preserving
  raw process names such as `syspolicyd`. Sampling runs only while the popover or Details
  window is open.
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
  **fresh tokens** (non-cached input + output); cached-context re-reads are shown
  separately. If enabled, Claude's token counts come the same way — live from the
  per-message usage records in `~/.claude/projects/**.jsonl` transcripts.

  Glancebar keeps a persistent incremental index at
  `~/Library/Application Support/Glancebar/ai-reader-state-v2.json`. The cache stores
  file identity/offset metadata, day totals, opaque hashes, and the last Codex limits —
  never transcript text, prompts, responses, or OAuth credentials. It is written
  atomically with mode `0600`. Each catch-up pass has one global 16 MiB / 350 ms budget,
  visits newest activity first, and exposes explicit indexing progress instead of
  presenting partial history as complete. It detects appends, rotations, inode
  replacement, truncation/regrowth, and time-zone changes safely.

  Claude's *quota* gauge has no on-disk source (Claude Code fetches it from the API at
  display time), so it fills in one of two ways. The options menu has an **opt-in**
  "Claude account status via Keychain/API" toggle, off by default. Enabling it first presents
  an in-app confirmation that explains the trust boundary. If confirmed, Glancebar
  invokes Apple's signed `/usr/bin/security` tool to read the OAuth token Claude Code
  maintains in the `Claude Code-credentials` Keychain item. Because Keychain evaluates
  the Apple-signed tool performing the read rather than Glancebar itself, the read is
  normally silent: **macOS does not present a Keychain permission prompt for Glancebar**.

  Glancebar then polls the Anthropic usage endpoint at most every 15 minutes. The token
  is kept in process memory only until expiry, never written or refreshed by Glancebar,
  and sent only to `api.anthropic.com`. This integration depends on Claude Code's private
  Keychain layout and an undocumented account endpoint; it is not a stable public API
  contract and may stop working when Claude Code or Anthropic changes. If the response
  reports paid overage usage at or above 100%, Glancebar shows an explicit red 0% status
  instead of a missing gauge. Alternatively, provide `~/.glancebar/ai-status.json`,
  which overrides either provider's gauge:

  ```json
  {
    "Claude": { "remainingPercent": 42, "resetAt": "2026-06-10T19:00:00+10:00" }
  }
  ```

  Claude transcript token totals are a separate **opt-in** toggle because transcript
  JSONL files contain conversation records. Glancebar extracts usage counters and
  timestamps, then persists only file identity/offset metadata, daily totals, and
  opaque message hashes in its protected local index—not prompts or responses. With
  both Claude toggles off, Glancebar reads local Codex state only—never Claude auth
  files or transcripts—and sends no network requests.

  `--dump` is local-only by default. Passing `--online` or setting
  `GLANCEBAR_ALLOW_ACCOUNT=1` permits the account request only after the integration
  has already been enabled in the GUI; neither switch enables credential access by
  itself. Other environment values, including `0`, do not grant online access.

  App signing does not change this credential-access behavior: `/usr/bin/security` is
  the process Keychain evaluates. Signing is still required for normal macOS distribution,
  but Glancebar never auto-selects an installed identity. See
  [`docs/RELEASING.md`](docs/RELEASING.md) for the explicit signing and notarization flow.

The time estimator, sampled-energy-impact grouping, process-stat grouping, rate-limit
selection, and log parsing have unit/regression tests. `./tests.sh` also runs an isolated
AIReader integration suite covering persistence, catch-up, append, replacement,
truncate/regrow, and privacy-safe deduplication. The IORegistry,
disk, `top`, `ps`, and AppKit plumbing live in the app shell. CI repeats the sanitizer,
static-analysis, Universal 2 build, bundle-version, architecture, and signing checks.

## Repository

```
glancebar/
├── Sources/pure.{h,m}    # pure logic: estimators, grouping, rate limits, parsing
├── Sources/main.m        # readers, sampling, CLI, popover + details UI
├── Tests/                # unit/regression and incremental-reader integration tests
├── Resources/            # source PNG and packaged macOS app icon
├── tools/mockup.m        # renders the example-data docs screenshot
├── .github/workflows/    # macOS sanitizer, analyzer, build, and bundle gate
├── build.sh · tests.sh · Info.plist
└── docs/                 # screenshot and maintainer release checklist
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
