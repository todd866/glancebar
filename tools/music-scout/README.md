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
| `radio_enabled` | false | Read station playlists (`radio.py`) as a candidate source |
| `radio_stations` | all + `triplej` | Stations to read (`kexp nts bbc6 wfmu rrr pbs 4zzz rtr triplej`) |
| `radio_days` | 7 | Look-back window |
| `radio_max_candidates` | 15 | Radio candidates per night (multi-station first) |
| `radio_max_single` | 5 | Of those, one-offs (one station each in turn) |
| `radio_max_requests` | 700 | Request budget per run, all hosts |
| `radio_min_gap_seconds` | 2 | Gap between requests to one host |
| `radio_max_seconds` | 1500 | Time limit for the radio step |
| `radio_cache_days` | 14 | Cached responses kept |
| `backcatalogue_enabled` | false | Older records (`backcatalogue.py`) as a candidate source, with the weekly split below |
| `backcatalogue_share` | 0.5 | Share of `tracks_per_week` kept for back catalogue; the rest is new (radio, Shazams, new releases, taste) |
| `decades` | 1960s–2010s | Back-catalogue decades, filled roughly equally each week |
| `backcatalogue_max_candidates` | 20 | Back-catalogue rows offered per night (never more than the back half of the week has room for) |
| `backcatalogue_lookups` | 100 | iTunes lookups per night to date radio plays (remembered in `backcatalogue/years.json`) |
| `backcatalogue_max_seconds` | 900 | Time limit for the back-catalogue step's lookups |
| `backcatalogue_lists` | all | Canon lists read (`grammy-hof-*`, `pazz-jop`, `rolling-stone-500`, `mercury`, `polaris`, `amp`) |
| `backcatalogue_refresh_days` | 30 | A canon list is fetched again after this |
| `backcatalogue_llm` | true | Ask the taste LLM for older records near his artists |
| `backcatalogue_llm_suggestions` | 24 | Tracks requested from that prompt |
| `status_remote` | `glancebar-music:glancebar-music` | rclone remote for `scout-status.json` |
| `status_remote_path` | `radio/scout-status.json` | Path in that remote |
| `rclone` | `/opt/homebrew/bin/rclone` | rclone binary (launchd's PATH has no Homebrew) |

## State (`~/.local/state/glancebar-music-scout/`)

| File | Purpose |
|------|---------|
| `candidates.json` | Last `candidates` output |
| `queue.json` | Ranked queue after `rank` |
| `ledger.jsonl` | Append-only offered / acquired / failed history |
| `new-music.json` | Playlist for the Glancebar **New music** tile |
| `source-stats.json` | Per-source counts; flags sources empty ≥3 nights |
| `last-run.json` | Last `run` summary for `status` |
| `scout-status.json` | Public summary copied to R2 after each `run` (see below) |
| `backcatalogue/` | Canon list copies (`lists/`), HTTP cache, `years.json` (release years and catalogue matches) |
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
python3 tools/music-scout/scout.py publish-status   # write scout-status.json and copy it to R2
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

4. **radio** (when `radio_enabled`) — public playlists of KEXP, NTS, BBC 6 Music, WFMU,
   RRR, PBS, 4ZZZ and RTR FM (`radio.py`; endpoints, politeness and ranking in
   `docs/music.md`, "Heard on the radio"), plus triple j from the selector's `plays.jsonl`.
   Tracks heard on two or more stations first; `source` is `radio:<station>`, with
   `stations`, `plays`, `heard` and a `why` such as "Heard on KEXP and PBS, latest 16 Nov".
   Cache and per-station plays: `radio-cache/` in the state folder.

5. **backcatalogue** (when `backcatalogue_enabled`) — older records, 1960s to 2010s
   (`backcatalogue.py`; sources, politeness and the weekly split in `docs/music.md`, "Back catalogue").
   Radio plays radio.py already stored, dated by the station's year or the earliest iTunes release;
   critics' canon lists and prizes read from Wikipedia; and the taste LLM asked for older records near
   his artists. Every row has `year`, `decade`, `era: "back"`, `source` `back:canon|radio|llm`, and
   `canon` / `stations` for its support. Every candidate gets `era` (the half of the week: `back` for
   this source, `new` for all others, radio included whatever its year) and `year` / `decade` where
   known; `rank` keeps about `backcatalogue_share` of the week back catalogue, decades in turn.

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

No network; mixpool, iTunes, `ai-pick`, and `amdl` are stubbed. `test_radio.py` checks each
station parser against the saved pages in `fixtures/radio/` and drives the readers through a
fake transport. `test_backcatalogue.py` does the same for the canon lists (trimmed pages in
`fixtures/canon/`), robots.txt, the decade split, the rank quota and the status document.

## `scout-status.json` (R2 `radio/scout-status.json`, for the web radio's Profile page)

```json
{"schemaVersion": 1, "at": "…Z", "acquiredThisWeek": 31, "acquiredGbThisWeek": 1.2,
 "budgetTracks": 200, "budgetGb": 10, "backcatalogueEnabled": true, "backcatalogueShare": 0.5,
 "decades": ["1960s", "…"], "byDecadeThisWeek": {"1960s": 3, "…": 0, "2020s": 14},
 "newVsBack": {"new": 18, "back": 13},
 "lastRun": {"at": "…Z", "ok": true, "dryRun": false, "queue": 40, "acquired": 28, "failed": 1,
             "noMatch": 0, "candidates": {"radio": 40, "backcatalogue": 20}, "errors": 0}}
```

Counts and flags only (no paths, no error text). Written after every `run`, also when it fails
or defers; an upload failure is printed and never fails the run.

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
