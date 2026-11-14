# music-scout

Nightly pipeline to surface interesting new lossless music and acquire a small
weekly budget via mixpool's existing `amdl` path. State is local JSON; each
stage is idempotent and safe to rerun.

## Configuration

`~/.config/glancebar/music-scout.json` (every field optional):

| Key | Default | Purpose |
|-----|---------|---------|
| `tracks_per_week` | 20 | Max acquisitions per rolling 7 days |
| `gb_per_week` | 1.5 | Max download volume per week (binary GiB, tracked from real bytes) |
| `mb_per_minute` | 7 | Lossless size estimate from iTunes duration before acquire |
| `fresh_days` | 14 | `publish` window for the New music tile |
| `exploration_share` | 0.30 | Minimum share reserved for taste-expansion rows in `rank` |
| `max_per_artist_week` | 2 | Per-artist cap including recent ledger offers |
| `new_release_days` | 60 | iTunes new-release lookback |
| `llm_suggestions` | 15 | Tracks requested from the taste LLM prompt |
| `new_music_path` | state dir | Output playlist JSON for the app tile |
| `media_share` | `~/.local/state/mac-sync/media` | Synced Shazam / like signals |
| `shazam_fresh_days` | 30 | Shazam still counts as fresh |
| `shazam_backlog_per_run` | 5 | Older Shazams offered per night |
| `storefront` | `au` | Apple Music URLs |
| `playback_log` | `~/Library/Logs/Glancebar/playback.jsonl` | Skip/reject heuristics |
| `reject_skips` | 2 | Early skip days before reject |

## State (`~/.local/state/glancebar-music-scout/`)

| File | Purpose |
|------|---------|
| `candidates.json` | Last `candidates` output |
| `queue.json` | Ranked queue after `rank` |
| `ledger.jsonl` | Append-only offered / acquired / failed history |
| `new-music.json` | Playlist for the Glancebar **New music** tile |
| `source-stats.json` | Per-source counts; flags sources empty ≥3 nights |
| `last-run.json` | Last `run` summary for `status` |
| `scout.lock` | Exclusive lock for state-changing commands |

## Commands

```bash
python3 tools/music-scout/scout.py candidates
python3 tools/music-scout/scout.py rank
python3 tools/music-scout/scout.py acquire          # dry-run (default)
python3 tools/music-scout/scout.py acquire --go       # real amdl on M5
python3 tools/music-scout/scout.py acquire --go --limit 1  # supervised single-track trial
python3 tools/music-scout/scout.py publish
python3 tools/music-scout/scout.py status           # exit 1 if unhealthy
python3 tools/music-scout/scout.py run [--go]
```

### Shared media record (Shazam & TV likes)

`candidates` also reads the synced media ledger at
`~/.local/state/mac-sync/media/signals-*.json` (see repo `SCHEMA.md`).

1. **shazam** — tracks with a Shazam signal that are not owned, not disliked, and
   not rejected. Fresh Shazams (within `shazam_fresh_days`, default 30) are
   **priority** candidates with a high score; older Shazams enter at most
   `shazam_backlog_per_run` per night (newest first). `why` is e.g. `Shazamed 14 Nov`
   (local date). Apple Music id → `track_id` / song URL when known (skips iTunes
   search on acquire).
2. **tv-like** — TV `like` signals (not owned / not rejected). Always priority;
   `why` is e.g. `Liked on the TV 12 Nov`.

In **rank**, rows with `priority: true` are placed above all novelty tiers
(ordered by score), ignore `max_per_artist_week` and `owned_artist_share_max`, and
do not count toward the taste-expansion share. They still respect weekly track/GB
budgets and are dropped when already owned or hearted.

**Rejection:** merged `dislike` signals; feedback whose last event is `dislike` or
`less`; a permanent `rejected` ledger row; and (when playback logs allow) scout
tracks skipped early via `click-next` on multiple days without ever finishing
(`auto-advance`). Rejected keys are omitted from candidates, rank, and publish.

### Other sources (`candidates`)

1. **triple j** — reads `picks` from `~/.local/state/selector/station.json`
   (output of `triplej.py queue`; no ABC re-fetch).
2. **new-release** — iTunes Search/Lookup via mixpool helpers for albums in the
   last `new_release_days` from artists in the library export, Apple favourites
   (`music-sync/inventory.json`), and hearts.
3. **taste-expansion** — `ai-pick --engines claude,codex,cursor --min 20`
   (exit **75** = skip tonight). Each suggestion is confirmed on the iTunes
   Search API before it counts.

### Acquire guards

Exit **75** (defer) when not on Apple **M5**, when
`~/.local/state/METERED_LINK` exists, or on battery power. Real pulls call mixpool's `run_amdl_detailed` (wraps `_run_amdl`, diffs
`~/Music/Apple Music` before/after for bytes and paths). New files are copied into
`~/Music/Glancebar Lossless/` at the same relative path for same-night playback.

### External assumptions (read-only)

| Tool | Paths used |
|------|------------|
| triplej | `~/.local/state/selector/station.json` |
| mixpool | `itunes_*`, `_run_amdl`; `~/.local/state/glancebar-mix/` |
| music-library | `catalogue.json` under its state dir |
| music-sync | `inventory.json` (`am_fav`) |
| Glancebar | `mix/feedback.jsonl`, `selector/hearts.json`, YouTube Liked names |

This tool never deletes or moves audio files.

## Launchd job (plist only; not installed here)

`tools/music-scout/com.iantodd.glancebar-music-scout.plist` — **03:10** on the M5,
stdout/stderr under `~/.local/state/glancebar-music-scout/`. Installs with the usual
`launchctl bootstrap` flow when ready.

Morning check can run `scout.py status` (nonzero when nothing acquired in 7
days or the last `run` failed).

## Tests

```bash
python3 -m unittest discover -s tools/music-scout -v
```

No network; mixpool, iTunes, `ai-pick`, and `amdl` are stubbed.

## `new-music.json` track shape (for offline-cache)

Each published track includes identity the offline helper can match:

```json
{
  "track_key": "artist|title",
  "artist": "…",
  "title": "…",
  "album": "…",
  "duration_seconds": 245.5,
  "acquired_at": "2026-11-10T00:00:00Z",
  "local_path": "/absolute/when/on/this/Mac.m4a",
  "catalogue_relative_path": "Artist/Album/track.m4a",
  "sha256": "64 lowercase hex"
}
```

`local_path` or (`catalogue_relative_path` + `sha256`) are set when known after acquire.
