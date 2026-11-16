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

## Tests

```bash
python3 -m unittest discover -s tools/music-embed -v
```

No network, no `google-genai`, and no real ffmpeg/ffprobe.

## Flags

Common: `--catalogue`, `--root`, `--ffmpeg-dir` (default `/opt/homebrew/bin`),
`--state`, `--model` (default `gemini-embedding-2`).