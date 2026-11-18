# music-embed

Resumable CLI to embed every track in the Glancebar music library with
`gemini-embedding-2` (audio in, 3072-D vectors) via the Gemini **Batch API**.

State and outputs live under `~/.local/state/glancebar-music-embed/` by default.
Catalogue input: `~/.local/state/glancebar-music-library/catalogue.json`.
Masters root: `/Volumes/OTV Mirror/Music/Apple Music`.

## Setup

```bash
STATE=~/.local/state/glancebar-music-embed
python3 -m venv "$STATE/venv"
"$STATE/venv/bin/pip" install google-genai
export GEMINI_API_KEY=...   # never commit or log this
```

Run commands with `"$STATE/venv/bin/python"` or activate the venv.

## Pipeline

```bash
python3 tools/music-embed/embed.py plan
python3 tools/music-embed/embed.py clips          # --limit N for trials
python3 tools/music-embed/embed.py build
python3 tools/music-embed/embed.py cost
python3 tools/music-embed/embed.py preflight      # live API check (2 clips)
python3 tools/music-embed/embed.py submit         # --dry-run
python3 tools/music-embed/embed.py poll
python3 tools/music-embed/embed.py collect
python3 tools/music-embed/embed.py neighbours "artist title" -k 5
```

After failures: `build --only-failed` from `errors.jsonl`, then `submit --resubmit shard-NNN`.

## Nightly map refresh (incremental)

New songs are embedded every night without rewriting the existing rows.
launchd `com.iantodd.glancebar-music-embed` on the M5 (plist here; `utc-daily --at 20:45`, after
the 19:40Z push writes the catalogue) runs `nightly-kick.sh`, which:

1. counts songs downloaded on the M5 (hot set, pending Apple Music pulls) that the bucket's
   catalogue lacks (`embed.py local-gap`) and hands that to the M2;
2. runs `nightly.sh` on the M2 over ssh (as the push does: a LaunchAgent on the M2 cannot read
   the masters drive, ledger W17). That script reads the key from `~/.config/glancebar/gemini.env`
   (mode 600, M2 only), skips fetching and embedding on a metered link, and runs
   `increment collect` (merge finished jobs) → `increment prepare` (under `heavy-slot`: fetch
   each master from the drive under `disk-slot --nowait`, or from R2 when the drive is busy or
   unreadable; cut clips) → `increment submit` (one Batch API job) → `increment wait`
   (up to 2 h; anything later is merged the next night) → `gaps --upload`;
3. copies `vectors/tracks.f32` + `tracks-index.jsonl`, `gaps.json` and `nightly-status.json`
   back to `~/.local/state/glancebar-music-embed/` on the M5 and, when the vectors changed,
   rewrites `mix/music-space.json` with `embed.py export`.

Incremental state is in `incremental/` (`jobs.json`, `prepared.json`, `batches/`, `results/`),
apart from the first run's `jobs.json`. Merges only append rows for ids not yet present, check
that each `.f32` holds exactly one row per index line before and after, keep the first run's
matrices in `vectors/baseline/` and the pair from before the last merge in `vectors/prev/`.
After a nightly merge, `collect` refuses (it rebuilds from the first run's jobs and would drop
the new rows).

**Spend cap.** `$5` a UTC day by default (`--cap-usd` or `$MUSIC_EMBED_CAP_USD`), about 2¢ a song
at the Batch price. `increment submit` takes a lock (`spend.lock`), reads `spend.json`, and
writes the job's estimated cost into today's total before anything is uploaded; it trims the
job to what is left, and refuses when nothing fits. A missing or unreadable ledger submits
nothing (`embed.py spend --init` creates it once). A failed upload keeps its reservation.
`embed.py spend` shows today's total.

**Gap report.** `embed.py gaps --upload` writes `gaps.json` and copies it to the bucket as
`radio/gaps.json`: `inR2NotEmbedded`, `embeddedNotInR2` (vectors with no song in R2, named in
`embeddedNotInR2Songs`; nothing is deleted), `downloadedNotInR2` (from the M5, or null),
`embedSpendTodayUsd`, `capUsd`. The M5's morning media check shows it as the `embeddings` row.

After new vectors, the web radio's bundle is rebuilt on the M5 with
`python3 ~/Projects/music-radio/tools/build_space.py`.

## Tests

```bash
python3 -m unittest discover -s tools/music-embed -v
```

No network, no `google-genai`, and no real ffmpeg/ffprobe.

## Flags

Common: `--catalogue`, `--root`, `--ffmpeg-dir` (default `/opt/homebrew/bin`),
`--state`, `--model` (default `gemini-embedding-2`).