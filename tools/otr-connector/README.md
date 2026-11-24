# Glancebar OtR Connector

Lightweight Python 3 standard-library HTTP server exposing Glancebar's local lossless library and playback remote controls to Onto the Radio (OtR) clients.

## Quickstart

```sh
python3 tools/otr-connector/otr_connector.py --host 127.0.0.1 --port 8787
```

On first launch, if no passphrase is supplied via `--pass`, `OTR_CONNECTOR_PASS`, or an existing `--pass-file` (default `~/.local/state/glancebar-otr/passphrase`), a URL-safe secret is generated and saved with `0600` permissions.

### Options

| Flag | Default | Description |
| --- | --- | --- |
| `--host` | `127.0.0.1` | Bind address |
| `--port` | `8787` | Listen port |
| `--name` | `Glancebar (Mac)` | Server display name |
| `--mix-dir` | `~/Library/Application Support/Glancebar/mix` | Glancebar mix metadata and `feedback.jsonl` directory |
| `--hot-dir` | `~/Music/Glancebar Lossless` | Lossless audio root scanned for remaining tracks |
| `--playlog` | `~/Library/Logs/Glancebar/playback.jsonl` | Glancebar playback event log |
| `--hearts` | `~/.local/state/selector/hearts.json` | Hearted tracks state file |
| `--state-dir` | `~/.local/state/glancebar-otr` | Connector state and generated passphrase directory |
| `--manifold-hub` | `https://manifold-chi.vercel.app` | Manifold lens hub URL |
| `--offline` | `false` | Skip network fetches |
| `--pass` / `--pass-file` | `<state-dir>/passphrase` | Shared secret or path to secret file |

## API Endpoints

All endpoints except `POST /api/login` require either an `otr_session` HTTP cookie (issued on login) or `Authorization: Bearer <passphrase>`.

- `POST /api/login` — Authenticate with `{"pass": "...", "name": "..."}`; returns `{"name", "capabilities": ["library", "glancebar-remote"]}` and sets `otr_session`.
- `GET /api/home` — Returns `library` song tiles and `stations` tiles (`Dance`, `Alt`, `Rap`, `Chill`, `New music`, `All Lossless`, plus Manifold radio lenses).
- `POST /api/queue` — Accepts `{"mood": "station:<id>"|"<kind>", "n": 18}` and returns ranked `picks` scored from `music-space.json`, `library.json`, and `feedback.jsonl`.
- `GET` / `HEAD /api/audio/<sha>` — Streams audio bytes with `200 OK` or `206 Partial Content` (`Accept-Ranges`, `Content-Range`).
- `GET /api/art/<sha>` — Serves track cover art (`image/jpeg` or `image/png`).
- `POST /api/event` — Records playback/taste feedback (`like`, `dislike`, `finish`, etc.) into `<mix-dir>/feedback.jsonl` with `"source": "otr"`.
- `GET /api/glancebar/now` — Returns current Glancebar playback state (`state`, `title`, `artist`, `liked`, `host`, `epoch`).
- `POST /api/glancebar/cmd` — Dispatches `play`, `pause`, `toggle`, `next`, `prev`, `like`, `dislike`, or `mood:<kind>`.

## Tests

```sh
python3 -m unittest discover -s tools/otr-connector -v
```
