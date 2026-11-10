# Saved offline playlists

## Contract

A visible playlist is a fixed, ordered snapshot. The primary export playlist still
plays when at least one requested recording is verified on this Mac (only those
tracks, in order; missing entries are skipped). Seed mixes and the New music tile
wait until every requested lossless track is on disk unless `musiclib.py` reports
it cannot fetch (metered link, offline, cap overflow, unmatched catalogue rows) —
then they play what is verified, dimmed with `N of M on this Mac`. While tracks are
still being fetched the tile stays dimmed with `fetching N of M`. There is no
cloud-streaming fallback, same-artist substitution, or silent gap-fill.

Seed mixes are persisted after generation and restored across app restarts.
`New picks` explicitly replaces them. The primary idle Play shuffles verified files
in `~/Music/YouTube Liked/` through Glancebar's own `AVQueuePlayer`. Mix ordering
still uses Claude or the rule-based draw, but only from library tracks that already
have a verified local file in the offline manifest.

Requests and manifests live under the app's Application Support `mix` directory.
The bundled Python helper references existing pinned files by default and never
starts a provider/player, downloads, moves, deletes or offloads audio. Explicit
copy mode exists as a separate maintenance action and fails closed below the
live M5 storage floor (at least 150 GB physically free). See
`tools/offline-cache/README.md` for the format and CLI.

Local availability is rechecked at most every five minutes while the music UI
is used, using a stat-keyed metadata/hash cache. A user Play rehashes the selected
queue in the background, with one verification at a time, and revalidates the
captured mapping before entering the local player. Pause, transport changes and
New picks invalidate pending starts. Paused saved queues survive network return.
Starting local playback pauses Apple Music when it is already playing; Glancebar
does not drive Music, Chrome, or the Selector deck as playback engines.

## Verification limits

A hash, supported container structure and unprotected sample description establish
stable local bytes, not successful decoding or audible output. No speaker,
headphone, phone, Bluetooth or provider playback is part of the silent tests.
Actual playback remains deliberately untested while the user's no-playback
restriction is in force. File changes by another process after validation can
still cause a later player error.

## November 8 audit

Read-only audit at 06:52 UTC, using the library exports from 00:41 UTC:

- Selected `YouTube Music Import`: 315 of 1,253 tracks verified on this Mac.
- Raw station queue: 31 of 40 verified; nine embedded-metadata conflicts. One
  concrete mismatch is a requested Delilah recording bound to a Glastonbury
  medley with Billie. These are not silently treated as equivalent versions.
- Saved seed recordings: Bad Bad News has an exact local match. Scud Books,
  Norwegian Wood, and No One Lasts Forever featuring David Cronenberg do not.
- The old app never persisted complete generated seed queues, so their exact
  historical coverage cannot be reconstructed from the seed cards alone.
- The exported `Glancebar Mix` snapshot contains 41 tracks, eight verified local
  matches. This is not necessarily any currently generated seed mix.

The Mac had about 64 GB physically free against its saved 150 GB floor. No real
media copies, downloads, deletions, playback or Bluetooth changes were performed.
The earlier Apple Music incident logged a download/lease asset-load timeout;
its phone-side impact is unproven without an iPhone trace.

## Rollout

This patch is source-only until explicitly installed/restarted at a safe time.
The existing app installation and user audio session were left untouched. Missing
recordings and storage capacity still need to be resolved; this patch makes those
gaps visible and safe rather than claiming they are already downloaded.

Validation completed on M2: the full `tests.sh` suite passed, including 25 Python
helper tests and intercepted controller regression tests. Light/dark offscreen
popover renders passed and were visually inspected. No app launch or installation
was performed. Compiler uses the repository's `-Wall -Wextra -Werror` settings.

## November 9 stale-display follow-up

After the 08:10 AEDT reboot, the installed bundle still had the headphone-route
fix (`fc753cf`, saved installation evidence), but no bundled offline helper or
manifest. Its old updater marker is not a reliable installed-source identifier.
At approximately 08:32 both Glancebar's accessibility view and Music's Mini Player
named Of Orpheus; the user also confirmed they had lined up. Earlier logs show
Of Agnes advancing in Music, not yesterday's asset-load timeout. A nonzero route
peak is evidence of samples being copied, not proof of audible speaker output.

A separate source fix prevents background status probes from superseding a pending
Music command's callback. A failed read now stops displaying a verified playing
state/advancing clock and reports unavailable playback status until a fresh read.
It does not claim to resolve every source-selection issue, or serialize repeated
user commands. Three silent regressions cover the probe guard, stale state and
recovery. The full test suite passed again on M2. No restart, playback action,
Bluetooth change or installation occurred; active listening and the separate MD3
release were left alone. Independent review of this small follow-up is pending
an available reviewer; the larger offline patch was reviewed previously.

## November 10 one-player phase

Glancebar music playback is only the in-app `AVQueuePlayer`. Transport controls,
seed tiles, the station tile, hearts, thumbs-up, and the scrubber all use that
player. Idle Play shuffles liked local files. Seed and New music tiles wait for the hot-set
sync unless fetch is blocked. Apple Music is paused when local playback starts and
is not otherwise controlled by Glancebar in this phase.
