# Glancebar music: what lives where

Decided 10 Nov 2026: Glancebar plays downloaded files with its own player and nothing else.
Lossless only. The laptop holds what is likely to play soon; everything else is in a private
R2 bucket and fetched as required. New music is found and acquired without being asked.

## Data

| What | Where | Notes |
|---|---|---|
| Lossless masters (Apple Music favourites + scout acquisitions, ALAC `.m4a`) | M2 `/Volumes/OTV Mirror/Music/Apple Music/` | Arrive from the M5 via `offload-am.sh` after each pull |
| Cold tier (copy of every master) + `catalogue.json` | Cloudflare R2 bucket `glancebar-music` (private, Oceania, Standard) | rclone remote `glancebar-music:` in `~/.config/rclone/rclone.conf` on the M5 and M2; key scoped to this bucket only |
| Lossless hot set | M5 `~/Music/Glancebar Lossless/` | Managed by `tools/music-library/musiclib.py`; capped (`cap_gb`), pinned to the M5 in the placement map |
| YouTube likes (AAC, best source available) | M5 `~/Music/YouTube Liked/` | `~/Projects/liked-music/sync.sh`, launchd `com.iantodd.liked-music-sync` |
| Daily new-music radio | M5 `~/Music/Glancebar Radio/` | `~/Projects/selector/tools/triplej`, launchd `com.iantodd.triplej-daily`; pinned to the M5 |
| Library export (track and playlist catalogue) | M5 `~/Music/Library-export/` | |
| Playlist requests, offline manifest, mix cache, feedback | M5 `~/Library/Application Support/Glancebar/mix/` | |
| Library tool state (catalogue cache, played, lock, last status) | `~/.local/state/glancebar-music-library/` (M5 and M2) | |
| Scout state (candidates, queue, ledger, `new-music.json`) | M5 `~/.local/state/glancebar-music-scout/` | |
| Config | `~/.config/glancebar/music-library.json`, `music-scout.json` | per Mac, not synced |
| Placement policy entries | `~/.config/fleet/placement.toml` (M5): "Music lossless masters", "Music lossless hot set", "New music radio" | hot set and radio carry `pins = ["m5"]` so `placement` never offloads them |

## Code

| Piece | Path |
|---|---|
| Player, tiles, output picker, "playing elsewhere" line | `Sources/main.m`, `Sources/pure.m` |
| Offline playlists (requests, manifest, verification) | `tools/offline-cache/`, `docs/offline-playlists.md` |
| Hot set / cold tier (catalogue, push, plan, sync, status, touch) | `tools/music-library/` |
| New-music scout (candidates, rank, acquire, publish, status) | `tools/music-scout/` |
| Lossless acquisition (amdl; M5 only) | `tools/mixpool/` |
| Silent real-playback check | `tools/check-playback.m` (runs in `tests.sh`) |

## Jobs

| Job | Mac | State |
|---|---|---|
| `com.iantodd.mixpool-liked` (pull favourites lossless, then offload to the M2) | M5 | installed |
| `com.iantodd.liked-music-sync` | M5 | installed |
| `com.iantodd.triplej-daily` | M5 | installed |
| `com.iantodd.glancebar-music-push` (03:40: masters → R2, then catalogue; `~/.local/bin/glancebar-music-push`, status in `push-status.json`) | M2 | installed 10 Nov 2026 |
| hot-set sync (every few hours; the app also starts one on demand) | M5 | NOT YET INSTALLED |
| `com.iantodd.glancebar-music-scout` (`scout.py run --go` at 03:10; plist in `tools/music-scout/`, logs under `~/.local/state/glancebar-music-scout/`) | M5 | installed |

## Checks

`musiclib.py status` and `scout.py status` exit non-zero when an offered playlist has missing
tracks, a sync failed, or nothing was acquired for a week: these are the hooks for the
morning check. `defaults write com.iantodd.glancebar musicSilentQA -bool YES` runs the player
muted for verification.

## Scout acquisition timeline (M5)

1. **03:10** — `scout.py run --go` ranks the queue and acquires within the weekly budget via
   `mixpool.run_amdl_detailed` (real file sizes and paths land in `ledger.jsonl`).
2. **Same night** — after each successful pull, scout **copies** (never moves) new ALAC into
   `~/Music/Glancebar Lossless/` at the same relative path so Glancebar can play before
   offload. `publish` writes `new-music.json` with title, artist, album, and duration even when
   the Apple Music tree is later empty.
3. **After pull** — `~/.local/state/glancebar-mix/offload-am.sh` rsyncs
   `~/Music/Apple Music` to the M2, verifies sizes, then moves the local tree to Trash.
4. **03:40 (M5 → M2 over ssh)** — `glancebar-music-push` uploads masters to R2 and refreshes
   `catalogue.json`. Started on the M5 since 11 Nov 2026: as a LaunchAgent on the M2 the
   script could not read the external drive (workarounds ledger W17).
5. **Later (M5)** — `musiclib.py sync` fetches wanted tracks into the hot set; the New music
   tile and offline-cache can bind via `catalogue_relative_path` + `sha256` or metadata match.

## Catalogue matching and liked retries

`offline_cache.catalogue_match_keys` (used by `musiclib.match_track`) applies matching-only
normalisation: punctuation and `&`→`and`, primary artist before `feat.`/`ft.`, stripped
`(Remastered …)` / `- Single` / clean|explicit suffixes and `The` prefix variants. Suffixes
that name a different recording (`Remix`, `Live`, `Edit`, `Acoustic Version`) are never
stripped. An exact artist+title match behaves as before; a loose match is trusted only when
both sides know the duration and agree within 2 s. Two candidate paths still fail closed.

`mixpool.py retry-unmatched` (dry-run by default) re-walks `liked-pulled.json` `no_match` and
`failed` rows against the cached catalogue, then tries album-less and suffix-stripped iTunes
searches. The lead runs acquisitions; the worker only prints `would-acquire` lines.

## Scout novelty

`scout.py rank` tiers candidates: new primary artists first, already-owned artists capped at
`owned_artist_share_max` (default 30%), remixes of owned recordings last. Taste-expansion
prompts include `owned_artists_to_exclude`. Prefer `new-music.json` as the offline
`station:triplej` source once it holds **≥12** verified tracks (paths + hashes), so the tile
does not depend on selector queue paths under `~/Music/Glancebar Radio/`.

Supervised one-track trial on the M5 (mains, unmetered):

```bash
python3 tools/music-scout/scout.py acquire --go --limit 1
```

## Favourites bound to the wrong song (found 11 Nov 2026)

Until 11 Nov 2026 `mixpool.py pull-liked` accepted any search result by the right artist, so
some favourites were recorded as done with a different song (or a remix, live or instrumental
version). `itunes_song` now requires the title and the artist to agree. `mixpool.py
audit-liked` lists the affected rows (dry run); `--apply` moves them from `done` to
`wrong_song` in `liked-pulled.json` so the next `pull-liked` looks for the right song. The
files already downloaded stay in the masters folder.

`pull-liked` finds a song in three steps: the song search; if that leaves the song out (it
often does: "artist title" returns the artist's popular songs), the artist's own album list
and the wanted album's tracks; then the artist's songs. Catalogue calls are paced (about one
every three seconds) and a failed call is never recorded as "no match": the row is tried
again on the next run. `pull-liked --retry-no-match` looks again for rows recorded as
no-match by the weaker search.

## Things that went wrong on 11 Nov 2026, and what now catches them

- The favourites job hung for 42 hours on an `ssh` with no timeout (home-network name, away
  from home). `offload-am.sh` now tries the home name then the tailnet name, with connect
  timeouts and keep-alives, and waits its turn for the M2's drive with `disk-slot`.
- The wider matching made the app's status read take 17 s of CPU every 30 s. Matching is now
  indexed (0.1 s) with a speed test, and the app asks every ten minutes unless a sync or a
  request change asks sooner.
- The playback harness ran its later scenarios on a made-up output device, so every track
  failed and the timing checks passed against a dead player. It now restores a real output
  and asserts that audio is advancing.

## The scout's taste step never ran from the schedule (found 12 Nov 2026)

launchd starts the 03:10 job with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so `ai-pick` (in
`~/.local/bin`) was not found; the scout recorded that as "deferred" and threw the reason
away, and the run acquired nothing. The scout now builds its own search path for helper
commands (`_tool_env`), treats a command it cannot find as an error (only `ai-pick`'s own
exit 75 is a deferral), and writes the errors into `last-run.json`.

## Why did the music stop? The playback event log (12 Nov 2026)

The player writes one JSON line per event to `~/Library/Logs/Glancebar/playback.jsonl`
(2 MB, one older file kept): `rate` (playing, paused, waiting) with its `cause`, `remote`
(the command received), `track`, `drop`, `item-failed`, `stalled`, `devices` (outputs that
arrived or left), `output` (default output changed), `sleep`, `wake`, `launch`. Each line
carries the track, the position and the current output.

`tools/playback-log` prints it; `--since 30` for the last half hour; `--why` also asks the
system log whether each remote command came from a Bluetooth device. Causes: `click`,
`click-next`, `click-previous`, `playlist`, `remote-pause`, `remote-play`, `remote-toggle`
(a keyboard play/pause key sends toggle; headphones send a separate pause or play),
`auto-advance`, `crossfade`, `drop`, `devices-changed`, `output-changed`, `sleep`.
`unattributed` means the app did not ask for the change: read the events just before it.

Found with the system log before this existed: on 12 Nov 2026 the music "cut in and out"
because the Bluetooth headphones were sending Pause and Play commands, and their link was
dropping; the player had no stalls or errors.

## Metadata and cover art are kept with every download (12 Nov 2026)

Owner rule: every downloaded song keeps its metadata, album art included, and that record
lives on the M2's external drive with the masters.

- **In the file.** `amdl` writes full tags (title, artist, album, album artist, composer,
  genre, date, track and disc numbers, ISRC, UPC, copyright, lyrics) and a 1500 px cover into
  each `.m4a`, and a `cover.jpg` in the album folder. YouTube likes carry title, artist, date
  and the video thumbnail.
- **Checked at download.** `mixpool.run_amdl_detailed` runs `trackmeta.check_download` on each
  new file: it writes `cover.jpg` from the embedded art if the folder has none, and records
  what is missing (`metadata.gaps`) with the download, in the scout ledger and in
  `liked-pulled.json` (`metadata_gaps`). `tools/music-library/trackmeta.py check FILE...`
  does the same by hand; `show FILE` prints everything.
- **In the catalogue.** Each `catalogue.json` entry has `meta` (all of the above except the
  lyrics text; `hasLyrics`, and the cover's format, size and hash) and a real
  `durationSeconds`. Until this date the duration reader used the wrong bytes and every entry
  said 0.0, so no duration check ever ran.
- **Beside the masters.** Every catalogue build writes the same document to
  `<masters>/_metadata/library-metadata.json` on the M2's drive, and prints how many masters
  have incomplete metadata.
