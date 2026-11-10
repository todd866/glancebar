# Glancebar music library (lossless hot set)

Standard-library Python plus the `rclone` CLI. No cloud SDKs; credentials live in
`rclone config`. Glancebar plays only verified lossless files from the hot
directory; this tool keeps that set aligned with saved offline playlists and
the triple j station queue.

## Configuration

`~/.config/glancebar/music-library.json`:

```json
{
  "remote": "glancebar-lossless:apple-music",
  "hot_dir": "~/Music/Glancebar Lossless",
  "cap_gb": 15,
  "keep_days": 14
}
```

- **remote** — rclone remote path (see below). Masters upload here; the laptop
  reads `catalogue.json` and fetches tracks from the same tree.
- **hot_dir** — laptop lossless cache; relative paths mirror the masters tree.
- **cap_gb** — decimal gigabyte cap for `hot_dir` (fetch is refused if the plan
  would exceed this even after eviction).
- **keep_days** — do not evict files played or fetched within this window.

Today you can point **remote** at an SFTP tree on the M2, e.g.
`m2-music:/Volumes/OTV Mirror/Music/Apple Music`. Later, swap to a private
Cloudflare R2 remote with the same layout.

## State

All tool state under `~/.local/state/glancebar-music-library/`:

| File | Purpose |
|------|---------|
| `catalogue.json` | Cached copy of the remote catalogue |
| `catalogue-build-cache.json` | Incremental hash cache on the masters machine |
| `played.json` | Last play time per hot-set relative path (`touch`) |
| `fetched.json` | Last successful fetch time per path |
| `sync.lock` | Exclusive lock for `sync` |
| `last-status.json` | Last sync time and error |

## Playlist requests (app contract)

The laptop reads the same document the app already writes for offline-cache:

`~/Library/Application Support/Glancebar/mix/offline-requests.json`

```json
{
  "schemaVersion": 1,
  "playlists": [
    {
      "key": "seed:…",
      "title": "Mix",
      "tracks": [
        {
          "id": "persistent-id",
          "title": "Song",
          "artist": "Artist",
          "album": "Album"
        }
      ]
    }
  ]
}
```

The app aggregates seed mixes, the primary export playlist, and
`station:triplej` into this file (see `saveOfflineRequests` in the app). Every
`id` must be a nonempty string. Matching uses normalised **title + artist**
only (Unicode NFC, casefold, whitespace). Optional `duration` /
`durationSeconds` on a track must agree with the catalogue within 2 s when both
are present. Ambiguous or missing catalogue rows are reported, never guessed.

YouTube Liked and Glancebar Radio are **not** managed here; they stay local.

## Catalogue format

`catalogue.json` at the remote root:

```json
{
  "schemaVersion": 1,
  "generatedAt": 1700000000,
  "entries": [
    {
      "relativePath": "Artist/Album/track.m4a",
      "sizeBytes": 44123456,
      "mtimeNs": "…",
      "sha256": "64 lowercase hex",
      "tags": { "title": "…", "artist": "…", "album": "…" },
      "durationSeconds": 245.5
    }
  ]
}
```

Built on the masters machine from ALAC `.m4a` under a masters directory.
Incremental rebuild reuses entries whose size and mtime are unchanged.

## Commands

```
python3 tools/music-library/musiclib.py catalogue --masters /path/to/masters
python3 tools/music-library/musiclib.py push --masters /path/to/masters
python3 tools/music-library/musiclib.py plan [--refresh-catalogue]
python3 tools/music-library/musiclib.py sync [--allow-metered] [--refresh-catalogue]
python3 tools/music-library/musiclib.py status
python3 tools/music-library/musiclib.py touch /path/in/hot_dir/track.m4a
```

Optional flags: `--config`, `--state`, `--requests` (defaults to Application
Support mix path).

| Command | Where | Behaviour |
|---------|-------|-----------|
| `catalogue` | Masters | Walk masters, write local + upload `catalogue.json` |
| `push` | Masters | `rclone copy` masters → remote, `--checksum`, no deletes |
| `plan` | Laptop | JSON plan: wanted, local, `toFetch`, `unmatched`, `evict` |
| `sync` | Laptop | Fetch `.part` → verify sha256 → rename; evict to Trash |
| `status` | Laptop | Per-playlist counts; exit 1 if gaps or last sync error |
| `touch` | Laptop | Record play time for eviction |

Guards:

- Refuse `sync` fetch when `~/.local/state/METERED_LINK` exists unless
  `--allow-metered`.
- Refuse `sync` when the plan still exceeds `cap_gb` after eviction (lists
  affected playlists).
- `sync` exit **75** if another run holds the lock.
- Eviction only removes files under `hot_dir` that are not wanted, older than
  `keep_days` (play or fetch), and present on the remote (`rclone lsf`). Removed
  files go to `/usr/bin/trash`, never `rm`.

## Expected launchd jobs (not installed here)

**Masters (M2)** — nightly:

1. `musiclib.py catalogue --masters "/Volumes/OTV Mirror/Music/Apple Music/"`
2. `musiclib.py push --masters "…"`

**Laptop (M5)** — every few hours:

1. `musiclib.py sync --refresh-catalogue`

Morning check can run `musiclib.py status` (nonzero when anything offered is
missing or the last sync recorded an error).

## Tests

```
python3 -m unittest discover -s tools/music-library -v
```

Rclone integration tests skip when `rclone` is absent. Pure logic (matching,
plan, eviction, cap, metered, hash verify) runs without rclone.
