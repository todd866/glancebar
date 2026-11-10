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
| scout `run` (nightly) | M5 | NOT YET INSTALLED |

## Checks

`musiclib.py status` and `scout.py status` exit non-zero when an offered playlist has missing
tracks, a sync failed, or nothing was acquired for a week: these are the hooks for the
morning check. `defaults write com.iantodd.glancebar musicSilentQA -bool YES` runs the player
muted for verification.
