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
| `com.iantodd.glancebar-music-scout` (`scout.py run --go` at 03:10; plist in `tools/music-scout/`, logs under `~/.local/state/glancebar-music-scout/`) | M5 | plist only (not installed) |

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
