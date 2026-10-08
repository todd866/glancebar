# Glancebar

**One configurable macOS menu bar item for machine and AI status — at a glance.**

![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)
![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen.svg)

<p align="center">
  <img src="docs/screenshot.png?v=ac246d47" alt="Glancebar menu bar item and a compact instrument popover: one row each for storage, battery, and system, a mini player, and one AI quota row per provider" width="380">
</p>

## Overview

Glancebar puts the numbers that ruin your day in one compact menu bar item
(`💾 61%  🔋 76%` by default). The bar draws the same SF Symbols as the popover:
internal or external drive, `battery.N` (with a bolt while plugged in), and `cpu`,
at menu-bar size. Click it for a single native popover laid out like an instrument
panel: one row each for storage, battery, and system, a mini player, and one quota
row per AI provider (Cursor combines API and Grok/Composer in a dual meter). Machine rows lead with the symbol. AI rows lead with that
provider's own app icon and its name. Colour, the symbol, and the gauge carry the
state; the longer explanation sits on the row's tooltip.
A **Details…** window repeats those symbols on its tabs and section headings, and
keeps the fuller lists there without crowding the popover.

One item, one slot, **no third-party dependencies, bundled daemons, or bundled helper
executables**. Nothing it displays needs admin rights; the privileged actions are the
*Keep Awake* and *Low Power* switches, which set `pmset` with one click once
an optional rule is installed, or with your administrator password (no helper is installed—see below). Glancebar invokes standard macOS tools
such as `top`, `ps`, `sqlite3`, `pmset`, `osascript`, and (only after the Claude account
opt-in) `/usr/bin/security`.

## Features

- **Storage** — one row for the boot volume: percent used, a gauge (orange past 85%, red past 95%), and free space in short units. Finder-accurate free space counts purgeable data as free. Another mount over 85% full tints the symbol and is named on the tooltip, which also carries the volume name, capacity, and purgeable share. The row opens the Storage tab; every other volume stays in Details.
- **Battery** — one row: charge percent, a gauge, and either time until 20% (`2:43 to 20%`, or `…` while estimating), charging watts (`+1.4 W`, hidden when Current draw is off), or `AC` when plugged in and not charging. The symbol is the charge level, with a bolt while plugged in. While the charge limit is held at 80% the gauge has a tick at 80%, and a plugged-in battery that has stopped there reads `held 80%`. Clicking the battery symbol runs the Shortcuts actions `Glancebar Charge 80` and `Glancebar Charge Full` (macOS 26 Set Charge Limit; full lasts until tomorrow). If those shortcuts are not installed, the click opens Battery settings. Health and cycle count are on the row's tooltip; with Health on, the datum also gains `· 93%` when the column fits. The rest of the row opens the Battery tab, where sampled energy impact still lives. On battery the popover adds one **Burn** row under Battery: the Mac's measured draw (`9.4 W`) on a 20 W tape, split by app (the three heaviest in orange shades, the rest faint, and what apps don't account for — screen, chip, root services — in grey), with the heaviest app named (`Chrome 2.1 W`); the Battery row then shows time to 20% rather than repeating the watts. Per-app energy comes from the kernel's own per-process counters (`proc_pid_rusage`, no privilege, about 2 ms), sampled every two seconds only while the popover or Details is open, plus one snapshot when you unplug. The Battery tab lists each app's live watts and Wh since unplugging, the screen + system remainder, and the total Wh since unplug from the battery itself. Plugged in, the row disappears and the tab shows energy impact as before. There, plugged in, one **Power** row shows where the charger's watts go on a single bar: grey for the Mac, green for charge into the battery, orange when the battery is helping, and the empty track as charger headroom (`18.8 W` `of 20 W`). Process rows show the name, bar and figure; the description is on the tooltip.
- **Sound** — one control-bar row, not a device name. Previous, play, and next sit on the left and the current output's symbol on the right, centred in the row; the track (or "Liked Music" before anything is loaded) and a subtitle sit in the middle. A click cycles to the next output, in the same order as the device menu (virtual devices stay off the list unless they are already the default); a right-click or Option-click opens that menu, and so does a click when there is only one output. Choosing one sets the system output and the alert sound. **Switch to new outputs** (on by default, under ⋯) makes a newly connected Bluetooth, USB, or HDMI/DisplayPort device the default, including a Bluetooth speaker that appears as an input a moment before its output. Headphones are headphones or AirPods only; a Bluetooth speaker stays a speaker; HDMI is a display. Sound is not a menu bar segment.
- **Play music** — play starts your YouTube Music Liked Music, shuffled, from a random song, in the signed-in Google Chrome profile and without bringing Chrome forward. Previous and next are always there, dimmed until a track is loaded. The subtitle is `Artist · 1:23 / 4:03` while something is playing (the clock advances once a second from the last reading) and, when nothing is loaded, `Shuffle · YouTube Music`, `Shuffle · N offline`, or `No offline music`. While the popover is open, Glancebar re-reads the tab every few seconds. Shuffle is turned on when Glancebar starts playback, not on every refresh. If Chrome is not set to allow JavaScript from Apple Events, the buttons fall back to the system media key and one line under the row says how to turn that on. If Glancebar is not allowed to control Chrome, it says so and will not keep opening tabs. Offline, or if Chrome cannot open, the same buttons play the m4a files in `~/Music/YouTube Liked/` through Glancebar’s own player, shuffled. Glancebar does not fetch YouTube itself.
- **System** — one instrument row: a CPU gauge and percent, then memory pressure (the kernel's own verdict, not a heuristic) as the memory-chip symbol beside three rising pips, filled to the level and coloured by it. A swap symbol appears beside them only while the Mac is swapping. Figures and the full sentence are on the tooltip. The row opens the System tab, which keeps the process breakdowns. Memory and swap are reported in binary units and by Activity Monitor's own "used" formula, so the figures match the tool you would check them against.
- **AI status** — one row each for Claude, Codex and Cursor: the provider's own app icon (Claude, Cursor, or Codex / ChatGPT, read from the installed app; the old SF Symbol if it is not installed), then the name, a gauge, the percent left, and a reset that says what it is (`resets 21:00`, `resets Wed`, `resets 3 Nov`). The same icon and name are used on the Details rows and on the AI items in the ⋯ menu. Codex's official remaining-quota percentage comes from its own session logs, kept apart per allowance bucket so a spent plan window is never hidden behind an untouched side bucket; where requests bill once the plan is spent stays on the tooltip ("Requests now bill to credits · none available"). Claude shows the weekly allowance across all models (the 5-hour window is on the tooltip and in Details, never a second number). Each window in Details is coloured by its own remaining fraction, so a full window stays green when another window is spent. Cursor’s opt-in account response supplies separate API and Cursor-model allowances. One Cursor instrument uses two fixed thin lanes, API above Grok/Composer, with both percentages aligned vertically in the usual value column. The reset or account status stays in the usual datum column; hover names each pool in full. The popover, Overview and AI Details use the same compact meter. Legacy aggregate responses retain one Cursor row, and a missing pool is never invented. On single-value rows, a problem takes the datum instead — `signed out`, `rate limited`, `stale 2h` — in amber or red, with the full reason on the tooltip. Live per-day token totals, sessions, messages, tool calls and the per-model split stay in Details. History labels its unit, keeps session-only activity visible, and reports per-model session counts as sessions.
- **Configurable glance** — choose which menu-bar segments appear: storage, battery,
  and/or system. AI status is deliberately not among them: a single percentage in the bar
  cannot say which pool it belongs to, and the pool with the least left is rarely the one
  you are spending. It lives in the popover and the Details window, where each provider's
  windows, resets and staleness can be read properly.
- **Never evicted** — on notched Macs the item narrows one rung at a time to fit the
  space the notch and system items leave, giving up as little as possible at each step:
  every reading with its icons → the same readings without icons → the single most
  useful reading → a bare glyph. It widens back when space returns, and VoiceOver and
  the hover tooltip always carry the full summary at every width.
  Recovery includes free space before neighboring status items, which macOS moves
  left as Glancebar grows, so a packed row cannot trap it in the collapsed state.
- **Keep Awake and Low Power** — the popover's footer holds two labelled toggles, icon beside
  the words "Keep Awake" and "Low Power", the same symbols the menu bar uses for those modes.
  The pill fill shows on or off; the longer explanation is on each tooltip. They always match the menu bar because both read the same live system setting.
  *Keep Awake* stops the Mac sleeping at all — idle or with the lid closed (the display
  still sleeps) — by setting `pmset disablesleep`; a cup replaces the battery glyph while it's
  on, and Glancebar switches it off when it quits. *Low Power* flips macOS Low Power Mode for
  battery and adapter alike; the battery turns yellow while it's on, as macOS's own does.
  The first flip offers a one-time **one-click** setup: a sudoers rule limited to
  `pmset -a lowpowermode 0|1` and `pmset -a disablesleep 0|1`, installed with your password
  once; after that the switches change instantly, with no prompt. Any program running under
  your account could use the same four commands, so the worst it allows is keeping the Mac
  awake or toggling Low Power. Decline it and every change uses the standard admin prompt. Everything
  else — menu-bar readings, battery extras, AI integrations, Launch at Login — sits under
  **⋯ › Settings**.
- **Self-contained** — one binary, native AppKit, no runtime, no installer, no bundled
  helper, and no network requests unless you opt in. The only `sudo`-level actions are the
  Keep Awake and Low Power switches, through the optional four-command rule or the standard admin prompt.

The main popover is one row per instrument: boot-volume storage, battery, CPU / memory / swap, the mini player, and each AI provider. Cursor uses two thin lanes in one 32-point instrument: API above Grok/Composer, with a percentage beside each lane. Value and reset columns stay aligned with the other providers. Hover identifies the pools in full. Claude's gauge remains the weekly allowance across all models. A storage, battery, or system row opens the matching Details tab; the battery symbol itself toggles the charge limit. Those tabs use the same symbols as the popover. Overview names the boot volume, Battery, and System in the lead column; AI rows name the provider beside its app icon. **Details…** keeps every volume, process breakdowns, every quota window, and diagnostics. The ⋯ button's tooltip includes the last refresh times, and each item in that menu carries its symbol — the provider's own icon on the AI account items.

## Build & Install

```bash
./tests.sh                                  # run unit/regression + reader integration tests
./build.sh                                  # test, build Universal 2, then sign
cp -R build/Glancebar.app /Applications/    # install
open /Applications/Glancebar.app            # run
```

For GUI launches, use Finder, `open`, or Launch at Login. Do not run
`Glancebar.app/Contents/MacOS/Glancebar` without a CLI option: on macOS 26,
Control Centre can otherwise persistently attribute its menu-bar item to the
terminal or parent app. Glancebar detects that launch path and relaunches itself
through Launch Services before creating the item.

For layout diagnostics, launch with `GLANCEBAR_BAR_DEBUG=1` to log measured capacity,
tier widths, and host position. Also setting `GLANCEBAR_BAR_START_COLLAPSED=1` starts
at the glyph to exercise automatic recovery; it only applies to that diagnostic
launch and is not saved as a preference. Pass these through `open --env` when
launching a stopped app so Launch Services still establishes its identity.

The build uses `-Wall -Wextra -Werror`, the macOS hardened runtime, and both `arm64`
and `x86_64` by default. Set `GLANCEBAR_ARCHS=native` if the local toolchain cannot
cross-compile. Requires the Xcode Command Line Tools (`xcode-select --install`).

Signing prefers, in order: `GLANCEBAR_CODESIGN_IDENTITY`, then an installed
`Developer ID Application` identity (auto-selected when exactly one is present), then
the `Glancebar Self-Signed` cert, then ad-hoc.
Prefer a stable identity: ad-hoc signing pins the designated requirement to the code hash,
so every rebuild looks like a new program and Launch at Login is re-registered. It does not
affect the Keychain prompt — the Claude Code credential is read through Apple's
`/usr/bin/security`, which is judged against that tool's signature rather than Glancebar's.
Pass `GLANCEBAR_ADHOC=1` to force ad-hoc on a shared machine or in CI.

This repository does not currently advertise a prebuilt or notarized download; build
locally with `./build.sh`. Do not remove quarantine from an app obtained from someone
else unless you have independently verified it. Maintainers can follow
[`docs/RELEASING.md`](docs/RELEASING.md) to create a signed, notarized candidate.

Launch at Login can be enabled during first run or from ⋯ › Settings. You can
also manage it in **System Settings → General → Login Items**.

The bundled executable also has a stable headless interface:

```bash
build/Glancebar.app/Contents/MacOS/Glancebar --dump                 # human-readable, local only
build/Glancebar.app/Contents/MacOS/Glancebar --dump --json          # schemaVersion 1 JSON
build/Glancebar.app/Contents/MacOS/Glancebar --dump --strict --json # exit 2 if any source is partial
```

`--dump` also prints how old a cached limit figure is, matching the popover's rule
(anything older than the 15-minute poll interval says its age). `--help` and `--version`
are available for scripts. JSON is written by itself to
stdout; unknown options are usage errors. `--online` permits the Claude and Cursor
account requests only for integrations already enabled in Glancebar, and honours the
same 15-minute throttle as the app (a cached response younger than that is reused).
`GLANCEBAR_HOME=<dir>` redirects every home-relative read (`~/.codex`, `~/.claude`,
`~/.glancebar`, the state file) to a fixture tree; the preference toggles are not
redirected. In schema v1, each top-level source (`storage`, `battery`, `sampledEnergyImpact`, `system`, and
`ai`) exposes `available` and `error`; `partialSources` names every unavailable or
incomplete source that makes `--strict` exit 2. An unconfigured Claude account source
is optional; after `--online` explicitly requests an enabled integration, a failed or
stale account refresh is reported as `ai.account` and is strict-partial.

Cursor quota windows in `--dump --json` include stable `pool` values (`api` or `cursor`).
The `cursor` window also carries the API’s `autoBucketModels` list as `models` when
available. Consumers should use those identifiers rather than interpreting display
labels; the historical `autoPercentUsed` field is the Cursor-model pool. Explicit
pool percentages take precedence over legacy aggregate fields, including in cached
responses. A status-file override whose reset has elapsed is ignored in full.

## How It Works

- **Disk** — `mountedVolumeURLs` (hidden volumes skipped), preferring the Finder-style
  "important usage" free-space figure. That figure counts purgeable data (caches, staged
  updates, local snapshots) as free, which is what Finder shows and what you actually get
  back; when it is more than 1% of the volume, Details names the purgeable share so the
  headline is not mistaken for physically free bytes. `--dump --json` carries both
  (`availableBytes`, `physicalAvailableBytes`, `purgeableBytes`).
- **Battery** — the IORegistry `AppleSmartBattery` entry (charge, charging state, raw mAh
  capacity, amperage, voltage, cycle count, smoothed time-to-empty). The menu bar updates
  instantly on plug/unplug via an `IOPSNotification`, otherwise every 15s. The 80% charge
  limit is not a private API: Glancebar runs two Shortcuts you create with the macOS 26
  "Set Charge Limit" action, `Glancebar Charge 80` and `Glancebar Charge Full`, via
  `/usr/bin/shortcuts`. It remembers which one ran last. Full is treated as expired after
  24 hours, which is as long as "until tomorrow" lasts.
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
  `vm.swapusage`. "Used" is Activity Monitor's formula — app memory (anonymous pages
  less purgeable ones) plus wired plus compressed — and memory/swap print in binary
  units (GiB shown as GB, as Activity Monitor does) while volumes stay decimal like
  Finder. Top CPU/memory apps come from `ps`, normalized to the all-cores scale
  and measured by physical footprint (what Activity Monitor shows), grouped under parent
  apps where possible.
- **Keep Awake** — the footer toggle flips the system `SleepDisabled` power setting by
  running `/usr/bin/pmset -a disablesleep 0|1` as root: through Apple's `osascript`
  administrator prompt, or with `sudo -n` once the optional rule is installed.
  No LaunchDaemon or helper is installed; the only privileged file is that opt-in rule
  (`/etc/sudoers.d/glancebar`, limited to four `pmset` commands, removable from Settings).
  This is the only reliable way to defeat clamshell (lid-close) sleep;
  `caffeinate`/`IOPMAssertion` prevent idle sleep only, never lid-close. `SleepDisabled`
  persists in the system power plist across restarts, so the button and the menu-bar cup
  both read the live setting, and Glancebar turns it off when it quits (silently with the
  one-click rule; without it the setting stays until you switch it off — an awake Mac in a
  closed bag can overheat).
- **AI status** — Codex's limit gauge comes straight from its own session logs: each
  turn in `~/.codex/sessions/**.jsonl` (and rotated
  `~/.codex/archived_sessions/**.jsonl`) records OpenAI's official rate-limit state
  (`used_percent` and reset time per window) under a `limit_id` naming the allowance
  bucket it was billed to — `codex` for the plan allowance, `codex_<name>` for side
  buckets, `premium` once requests bill to credits. Codex meters several buckets at
  once and one session's snapshots alternate between them, so Glancebar keeps each
  bucket's windows apart. The compact popover shows one governing allowance per
  provider; Codex uses the general plan allowance, while Spark's separate allowance
  stays in Details > AI. A newer Spark observation does not imply that requests
  switched to Spark. Once an allowance is spent, Codex stops sending that bucket's
  windows — the next snapshots arrive under `premium` with `"primary": null` — so
  Glancebar carries the bucket's last window pair forward until its own `resets_at`
  passes, marks it cached, and keeps answering the question that matters: when the
  allowance comes back, and where requests bill meanwhile ("Requests now bill to
  credits · none available"). A `credits` balance is reported as context in Details; it
  is not a gauge (a zero balance is normal while the plan window still has room). If a
  snapshot ever arrives in a shape Glancebar cannot read — a renamed field, an unfamiliar
  meter — the row says which fields it did not recognise rather than reporting no status
  at all, so schema drift looks like schema drift and not like an idle account. The same
  per-turn records carry exact token deltas, which is how today/7-day totals are
  computed. Headline counts are **fresh tokens** (non-cached input + output);
  cached-context re-reads are shown separately. If enabled, Claude's token counts come
  the same way — live from the per-message usage records in `~/.claude/projects/**.jsonl`
  transcripts. Claude Code writes one line per content block with the same message id
  and a running usage figure; Glancebar counts each message once at its final reading
  (an earlier build kept the first line and under-counted output by about 40%). The
  transcripts also supply Claude's per-model split, sessions (subagent transcripts spend
  tokens but are not sessions), messages, tool calls and last activity; the
  `~/.claude/stats-cache.json` file, which Claude Code stopped updating in June 2026, is
  read only when transcript scanning is off.

  Glancebar keeps a persistent incremental index at
  `~/Library/Application Support/Glancebar/ai-reader-state-v2.json`. The cache stores
  file identity/offset metadata, day totals (per model), opaque per-message hashes with
  the counted reading, the last Codex limits per bucket, and — while the account toggles
  are on — the last Claude/Cursor account usage responses (never a token) — never
  transcript text, prompts, responses, or OAuth credentials. It is written atomically
  with mode `0600`. Each catch-up pass has one global 16 MiB / 350 ms budget,
  visits newest activity first, and exposes explicit indexing progress instead of
  presenting partial history as complete. It detects appends, rotations, inode
  replacement, truncation/regrowth, and time-zone changes safely.

  Claude's *quota* gauge has no on-disk source (Claude Code fetches it from the API at
  display time), so it fills in one of two ways. The account response carries a `limits`
  array (a 5-hour session window, the weekly window across models, and a weekly window
  scoped to one model, named after it); a window nobody has used yet has no reset time
  and shows as 100% left, "not started", rather than as a missing gauge. Because only
  Claude Code refreshes its OAuth token, the gauge goes stale while Claude Code is idle
  for longer than the token lives; the row then says how old the figure is. The Settings menu has an **opt-in**
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
  JSONL files contain conversation records. Glancebar extracts usage counters, the model
  id, tool-call counts and timestamps, then persists only file identity/offset metadata,
  daily totals, and opaque message hashes in its protected local index—not prompts or
  responses. With
  both Claude toggles off, Glancebar reads local Codex state only—never Claude auth
  files or transcripts—and sends no network requests.

  Cursor's quota gauge is a third **opt-in** (off by default), and only appears when
  Cursor's local app data is present on the Mac. Enabling it reads the signed-in JWT
  from Cursor's local `state.vscdb` (`cursorAuth/accessToken`) and polls
  `api2.cursor.sh` at most every 15 minutes for included plan usage. The token stays
  in process memory only and is never written by Glancebar. Like Claude's account
  integration, this depends on undocumented endpoints and may break when Cursor
  changes. Token totals for Cursor are not derived locally (Cursor does not expose
  per-turn usage logs the way Codex/Claude do).

  `--dump` is local-only by default. Passing `--online` or setting
  `GLANCEBAR_ALLOW_ACCOUNT=1` permits the Claude and Cursor account requests only after
  the integration has already been enabled in the GUI; neither switch enables credential
  access by itself. Other environment values, including `0`, do not grant online access.

  App signing does not change this credential-access behavior: `/usr/bin/security` is
  the process Keychain evaluates. Signing is still required for normal macOS distribution,
  and `build.sh` prefers an installed Developer ID automatically (pass `GLANCEBAR_ADHOC=1`
  to stop it). See
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
├── Sources/nowplaying.m  # MediaPlayer wrappers (kept out of main.m; its headers break subscripting)
├── Sources/main.m        # readers, sampling, CLI, popover + details UI
├── Tests/                # unit/regression and incremental-reader integration tests
├── Resources/            # source PNG and packaged macOS app icon
├── tools/mockup.m        # renders the example-data docs screenshot
├── .github/workflows/    # macOS sanitizer, analyzer, build, and bundle gate
├── build.sh · tests.sh · Info.plist
└── docs/                 # screenshot and maintainer release checklist
```

### A note on notched Macs

macOS hides a menu bar item wholesale when it no longer fits beside the notch —
system items (AirPods, Now Playing, Weather) can crowd one out with no warning.
Glancebar measures the space that actually exists and adapts, in rungs that cost as
little as possible: the full display when there's room; then the same readings with the
meter icons dropped, which is about a third narrower and still shows every number; then
the single reading that matters most (battery percentage, or the configured meter icons
when battery is disabled); then a bare gauge glyph. The Keep Awake cup outranks all of it
while it is on. The popover stays one click away at every
width.

No application can push another app's item aside — menu bar placement belongs to the
system, and an app only chooses its own width — so if the strip is genuinely full,
something has to give. Two things help. macOS squeezes out the item nearest the notch
first, so ⌘-dragging Glancebar to the right of an item you care less about makes that
one absorb the pressure instead. And hiding menu bar items you don't use (System
Settings → Control Center) returns real space to everything that remains. It re-expands automatically after
the space has stayed free for a while; only modest headroom is required, so
removing one neighboring icon can
restore the display without letting a transient AirPods connection make it flap.
Hover the item for the full summary at any width. Control Centre packs status items edge
to edge, so an item that is on the bar already fits: Glancebar narrows only when a
neighbour genuinely overlaps it, not merely because there is no slack beside it. An item
that was never placed at all — launching into a bar with no room — falls to the glyph
after 30 seconds rather than staying invisible, and grows back once space is measured.
None of this runs while the display is asleep: with the lid shut, the window list reports
none of the app's own windows, which is indistinguishable from having been evicted, so
Glancebar holds its width and re-measures when the display comes back.

## Credits

Built by Claude (Anthropic) and Codex (OpenAI), working from Ian Todd's brief and
direction — design, implementation, tests, the rendered screenshot, and this README.

## License

MIT — see [LICENSE](LICENSE).
