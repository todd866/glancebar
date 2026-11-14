# media-sync

One shared JSON record of music signals (Shazam, Glancebar hearts, Apple Music
favourites, YouTube likes, TV likes) plus health checks for the music pipeline.
Fleet morning and the menu-bar morning check read `check`; the TV music-video job
reads `export-likes`.

**Rule:** a Shazam is not a like — it means “what is this?”. Only hearts and explicit
likes count as likes.

## Commands

```bash
tools/media-sync/media_sync.py collect   # write share/signals-<host>.json
tools/media-sync/media_sync.py show      # merged human view
tools/media-sync/media_sync.py export-likes --out PATH
tools/media-sync/media_sync.py check     # PASS/WARN/FAIL lines + check.json
```

All commands accept `--config PATH` (default `~/.config/glancebar/media-sync.json`).

## Config keys

| Key | Default | Role |
|---|---|---|
| `host` | short hostname | id in file names |
| `share_dir` | `~/.local/state/mac-sync/media` | synced signal + check publish folder |
| `state_dir` | `~/.local/state/media-sync` | local `check.json`, `last-collect.json` |
| `shazam_db` | Apple Shazam sqlite | recognitions (read-only, no location columns) |
| `hearts_path` / `heart_history` | selector state | Glancebar hearts |
| `glancebar_feedback` | mix feedback jsonl | thumbs-up likes |
| `liked_pulled` | mixpool state | Apple Music favourites buckets |
| `yt_liked_dir` / `music_sync_inventory` | YouTube likes files or inventory fallback |
| `catalogue` | music-library cache | `owned` matching |
| `tv_storage` / `tv_music_videos` | off unless set | TV likes and on-disk videos |
| `check` | thresholds object | overrides for row timing (see below) |

Paths under `mixpool_state`, `apple_music_dir`, `music_library_state`, `scout_state`,
`selector_state`, and `tv_video_log` drive check rows when those inputs exist on the Mac.

## Check rows

| Row | Skipped when | Meaning |
|---|---|---|
| `ledger` | no local `signals-<host>.json` | track/like/shazam counts; stale file; bad sources |
| `shazam` | no Shazam db | fresh unowned shazams vs scout ledger |
| `favourites` | no `liked-pulled.json` | done/total lossless; pull-liked log age |
| `offload` | no Apple Music download dir | files waiting to offload |
| `upload` | no `push-status.json` | masters → R2 push |
| `scout` | no scout `last-run.json` | nightly scout health |
| `hot set` | no music-library `last-status.json` | hot-set sync |
| `triple j` | no `station.json` | selector station refresh |
| `tv videos` | `tv_video_log` empty | liked songs with a video file + log age |
| `tv likes` | `tv_storage` empty | TV-side likes readability |
| peer `check-*.json` | — | other Mac rows or stale warning |

Default thresholds live under `check` in config (hours/days as in the brief).

## Files written

- `<share>/signals-<host>.json` — this Mac’s signals (`SCHEMA.md` in repo brief)
- `<share>/check-<host>.json` — this Mac’s check rows for peers
- `<state_dir>/check.json` — local rows plus fresh peer rows