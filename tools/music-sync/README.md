# Likes sync

Copies likes between YouTube Music and Apple Music, in both directions. A track you liked on YouTube Music becomes an Apple Music favourite, and an Apple Music favourite becomes a YouTube Music like. It never un-likes or un-favourites anything.

`apply` is a dry run unless you pass `--apply`. `inventory` and `plan` only write local state. `inventory` does read the Music library.

## What it reads

YouTube Music likes come from the yt-dlp download archive at `~/Projects/liked-music/archive.txt`. Each liked track is a line `youtube <videoId>`. Title and artist come from the m4a files in `~/Music/YouTube Liked/`:

- `ffprobe` format or stream tags, when `ffprobe` is installed
- otherwise `mdls -name kMDItemTitle -name kMDItemAuthors`
- otherwise the filename `Artist - Title [videoId].m4a`

Apple Music favourites come from one Music AppleScript read of library playlist 1: name, artist, album, persistent ID, and favorited.

Override the paths with `MUSIC_SYNC_ARCHIVE` and `MUSIC_SYNC_YT_DIR` if you need to.

## State

`~/.local/state/music-sync/` (created on first use; override with `MUSIC_SYNC_STATE`):

- `inventory.json` — `{yt, am_fav}`
- `plan.json` — `yt_only` (favourite these in Apple Music), `am_only` (like these on YouTube Music), `matched`
- `applied.jsonl` — one line per attempt: `{at, side, key, action, result, ids}`
- `apple-developer-token.json` — the public web-player developer token and its `exp` claim. Refreshed when that claim has passed.

Names are matched lower-case, with `(feat. …)`, remaster suffixes, `(Official …)`, ` - Topic`, and punctuation removed. Anything still unmatched is paired when `difflib` scores the `artist title` string at 0.9 or above. Each track is used once.

A write into Apple Music (a library track, or a catalog search hit) is kept only when the artist matches after that same normalisation. Otherwise the line is `no-match`. A `no-match` is not a guess, and it is not a success, so a later run tries it again. `ok` lines are skipped. `error` lines are retried. Three errors in a row stop that run.

## Before a real run

Chrome has to be the Default profile, signed in to Google and to Apple Music at https://music.apple.com. In Chrome, turn on **View > Developer > Allow JavaScript from Apple Events**. macOS Automation must allow this terminal to control Music and Google Chrome.

Apple events run page JavaScript in an isolated world. `MusicKit`, `ytcfg`, and `ytmusic-app.networkManager` belong to the page and are not visible there. The DOM, `localStorage`, and cookies are shared.

The Apple Music developer token is a public ES256 JWT baked into the web player's JavaScript bundle. The tool fetches `https://music.apple.com/` (then `/au/home` if that page has no bundle) with a normal browser User-Agent, finds `/assets/index~*.js` or `index-*.js`, and otherwise scans every `<script src>` under `/assets/`. It reads the JWT from that bundle, caches it with its `exp` claim, and sends it as `Authorization: Bearer`. The user token stays in the browser: the script reads `media-user-token` from the cookie (or a matching storage key) and sends `Media-User-Token`. Reports show the first four characters of the user token. If the user token is missing, the script injects into the page's own world and asks MusicKit; if Content-Security-Policy or Trusted Types block that, the run says so. `probe-am` is read-only. It reports `developer: found (exp …)` and, when the user token is present, calls `GET /v1/me/storefront` and prints only the storefront id. It also says when this Chrome profile is not signed in to Apple Music.

YouTube Music reads `INNERTUBE_API_KEY` and `INNERTUBE_CONTEXT` from inline scripts (or from `ytcfg` when that global is visible) and `SAPISID` from the cookie.

Catalog search uses the Australia storefront (`/v1/catalog/au/`).

Apply opens one background Chrome tab for the side it is writing and closes that tab when the run finishes, including when it fails.

## Commands

From the repo root:

```bash
python3 tools/music-sync/likes_sync.py inventory
python3 tools/music-sync/likes_sync.py plan
python3 tools/music-sync/likes_sync.py probe-am
python3 tools/music-sync/likes_sync.py apply --side am --limit 25
python3 tools/music-sync/likes_sync.py apply --side yt --limit 25
```

Read `plan.json` and the dry-run lines. A real write is the same `apply` with `--apply`. The default limit is 25 tracks a run, with a 2–4 second pause between writes.

`--side am` favourites `yt_only` in Apple Music: if the song is already in the library it sets favorited; otherwise it searches the catalog, adds the song, and loves it. `--side yt` searches YouTube Music for each `am_only` favourite and likes the video.

## Nightly

Dry-run until `plan.json` looks right. Then a nightly job can apply both sides. It will not remove likes. Raise `--limit` only if you want more than 25 writes per side per night.

A side that hits three errors exits 1. The example still runs the other side.

```bash
#!/bin/sh
cd /path/to/glancebar
python3 tools/music-sync/likes_sync.py inventory || exit 1
python3 tools/music-sync/likes_sync.py plan || exit 1
python3 tools/music-sync/likes_sync.py apply --side am --limit 25 --apply
am=$?
python3 tools/music-sync/likes_sync.py apply --side yt --limit 25 --apply
yt=$?
[ "$am" -eq 0 ] && [ "$yt" -eq 0 ]
```
