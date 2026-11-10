# Exact offline playlist preparation

Standard-library Python helper, with no player, account, network or download calls.
Run Python 3.9+ for audit/reference preparation; explicit copying requires Python
3.11+ to read the live TOML placement policy without third-party dependencies.

```
python3 tools/offline-cache/offline_cache.py audit --requests /path/offline-requests.json
python3 tools/offline-cache/offline_cache.py prepare --requests /path/offline-requests.json --manifest /path/offline-manifest.json
```

`audit` only prints JSON. `prepare` publishes the same report atomically, plus a
metadata scan cache and advisory single-writer lock beside the manifest. It
references existing files by default, without duplicating any audio. Exit 0 means
every nonempty playlist has at least one verified on-disk track (and ordered paths
for those tracks); exit 2 means a usable report with gaps only; exit 75 means
another preparation is active; exit 1 means an input/policy/I/O error. Consumers
must reload reports on both 0 and 2 and validate their current requests against
ordered `requestedTrackIDs` and the actual files. Never trust `ready` alone.

Requests:

```
{"schemaVersion":1,"playlists":[{"key":"seed-ID","title":"Mix","tracks":[{"id":"persistent-ID","title":"Song","artist":"Artist","album":"Album"}]}]}
```

Manifest playlists retain `key`, `title`, `requestedTrackIDs`, `requestedTracks`
(the full ordered requested identity objects), and have ordered
`tracks` for successful entries, `missing` entries with reasons, `readyCount`,
`totalCount`, and `ready`. Verified entries retain the requested metadata and
include absolute `path`, `sizeBytes`, a SHA-256 digest, and decimal-string
`mtimeNs` and `inode` for cheap freshness checks before playback. Duplicates and ordering
are retained. Empty playlists are not ready. The optional `--index` is a trusted
local JSON object `{"tracks":[...]}` whose rows have `path`, plus a stable library
`id` and/or full title/artist/album. An ID does not override conflicting metadata.

Default source pools are the music-library `hot_dir` (`~/Music/Glancebar Lossless` by
default, from `~/.config/glancebar/music-library.json` when present), then
`~/Music/YouTube Liked`, `~/Music/Glancebar Radio`, and `~/Music/Glancebar Offline`.
Lossless files under `hot_dir` are preferred over byte-different lossy matches:
`select()` resolves ambiguity within the hot pool first, then falls back to other pools.
Requests may carry a trusted binding (`local_path` or `catalogue_relative_path` + `sha256`
from music-scout `publish`) matched by verified bytes without album-tuple equality.
Repeat `--root` to replace those defaults with pinned local pools. M4A/MP4
metadata is read directly from bounded iTunes text atoms, never inferred from
filenames or fuzzy song-title comparisons. Every artist/title/album field must
match, with only Unicode normalization, case and whitespace folding. Multiple
paths are ambiguous unless independent structural and hash checks establish
identical bytes. Exact-byte duplicates collapse deterministically, preferring
the default offline-cache directory. Different bytes remain ambiguous. Other audio formats can use
an explicit trusted index. A metadata match establishes recording identity, not
proof of valid decoding or universal DRM freedom. Known protected M4A/MP4 sample
entries (`drms`, `enca`, `encv`) in `stsd` are rejected, including sources supplied
by an explicit ID index. This is a headless byte/header check, not decoding proof.
Verification checks readable nonempty
regular file bytes and hashes, without instantiating any player. Cloud placeholders,
cloud storage paths, symlinks and `/Volumes`, `/Network`, `/net` paths are rejected.
No stale music-sync inventory or download-status flag is used as audio proof.

Optional copying is explicit:

```
python3 tools/offline-cache/offline_cache.py prepare --copy --requests /path/requests.json
```

Only exact selected local files are copied into `~/Music/Glancebar Offline` (or
`--cache`). Names are content hashes. Copies are byte-count and SHA-256 verified,
fsynced, and published without overwriting existing files. Sources are never
moved, deleted, offloaded, or touched. Only the command's own unpublished temporary
file is removed on failure. Existing valid copies are reused.

The M5 floor is at least **150,000,000,000 bytes** (decimal 150 GB), confirmed in
`~/.config/fleet/placement.toml`; a larger live M5 floor is respected. Missing or
unreadable live policy blocks copy. Free space uses physical filesystem free
blocks, not purgeable-inclusive capacity, with checks before allocation and each
copy chunk. Other writers can still consume space concurrently: this helper is
not a fleet-wide disk reservation service. Below the floor, existing local files
remain usable but new cache copies are blocked. No eviction is attempted.

No SSH fetching is implemented: home-machine audio is a gap until it has been
separately and explicitly transferred within storage policy. No full-library
mirroring, provider downloads, launch agents or schedules are installed.

Silent tests (small temporary synthetic files only):

```
python3 -m unittest discover -s tools/offline-cache -v
```

## Preparation cache schema

`offline-manifest.metadata.json` (or the manifest basename with `.metadata.json`)
is local preparation state, not a playback manifest. Schema version 3 is:

```
{
  "schemaVersion": 3,
  "metadata": {"/absolute/file.m4a": {"stamp": ["device", "inode", 123, "mtimeNs", "ctimeNs"], "tags": {"title": "Song", "artist": "Artist", "album": "Album"}}},
  "verified": {"/absolute/file.m4a": {"validationVersion": 3, "stamp": ["device", "inode", 123, "mtimeNs", "ctimeNs"], "info": {"path": "/absolute/file.m4a", "sizeBytes": 123, "sha256": "64 lowercase hex characters", "mtimeNs": "mtimeNs", "inode": "inode", "embeddedTags": {"title": "Song", "artist": "Artist", "album": "Album"}}}}
}
```

Stamps contain device/inode/size/mtime/ctime in that order; only size is a JSON
number. Unchanged successful verification is reused across `prepare` calls, so
rebuilding requests does not rehash every file. `ctime` also invalidates hashes
when content is changed and mtime subsequently restored. Each lookup still checks
that the file exists, is regular/nonempty/readable, and is not a symlink, excluded
location or dataless placeholder. As with any filesystem-stat cache, this assumes
the local cache and filesystem are trusted; it is not a hostile-writer integrity
boundary. An `audit` run ignores persisted caches, performs fresh verification,
and writes nothing. Old cache schemas are ignored and rebuilt on preparation.

MP4 verification additionally requires a valid bounded box structure, `ftyp`, an
audio `stsd` entry in the audio-track hierarchy, and a nonempty top-level `mdat`.
Metadata-only, truncated boxes and missing audio/media data are rejected. Version
3 verification stamps certify that these structural checks ran before caching.
This still does not decode audio samples or prove their codec-level validity.

Verified entries also retain `embeddedTags`. Any nonempty embedded title, artist
or album that contradicts a nonempty requested field rejects the recording, even
when an explicit index asserts the requested persistent ID. The check applies
before any optional copying and when a cached verification is reused.

Prepared copies are discoverable on subsequent preparation because the default
offline-cache directory is itself a source pool. The copy retains embedded tags.
Explicit `--root` overrides still replace all default pools. This provides no
permission to move or delete the originals.
