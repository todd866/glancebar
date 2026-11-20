# One music system (decided 19 Nov 2026)

Ian, 19 Nov 2026: "glancebar and onto the tv and now 6ian radio, we *need* to unify the music infrastructure."
Owner's copy (editable): https://claude.ai/artifact/PbJrUrdzhwp81tdNRA32XQ

Rule: every store has exactly one writer; Glancebar, Onto the TV and 6IAN only read it.

| Piece | One home | Only writer |
|---|---|---|
| Song ID | sha256 of the master + one alias table (Apple id, YouTube id, `embed.match_key` → sha) in R2 | catalogue builder |
| Catalogue | R2 `catalogue.json`, built from the R2 listing of every master root | catalogue builder (hub, nightly) |
| Files | masters in R2 + one hub drive; AAC and covers in R2 `radio/` | placer |
| Embeddings | `glancebar-music-embed/vectors` on the hub, mirrored to R2 | one embed function (checks the store first; Batch by default) |
| Song facts | one record per sha (MusicBrainz year, cover, lyrics, bio) | facts builder |
| Taste | one append-only event log per listener (Ian, mate, cousin, household TV) | one append API |
| Acquisition | one queue + one daily budget | acquisition worker on the hub |
| Spend | one ledger, charged on success only | embed function |

Verified 19 Nov on the hub: the 898 lane songs of 18 Nov are in neither `catalogue.json` (1,454 = library) nor
`tracks-index.jsonl`; `fetch_worker.place_now` discarded each 3072-D vector after placing it; `place_masters.py`
writes to Stash while the catalogue/push reads OTV Mirror; the spend ledger charged ~319 refused (429) calls.

Order: (1) stop the leaks — worker persists vectors via embed.py, ledger on success, catalogue covers both master
roots; (2) alias table; (3) taste log; (4) one acquisition queue/budget (scout + lane + stations + YouTube Music
recs; ≥70% released in the last two years, ≤3 songs per artist, `why` recorded); (5) facts builder; (6) masters on
one drive pool after the 26 Nov SanDisk, with the M2 drive lead. Ian's calls: daily embed budget, public pushes.

## What landed (19 Nov 2026)

| Step | Where | State |
|---|---|---|
| 1c Catalogue from the bucket | `tools/music-library/musiclib.py catalogue --from-remote`, `push.sh`, `push-kick.sh` | The R2 listing (`AM-Lossless/`, `AM-MV/`) is the catalogue. A readable root supplies hash and tags; the previous entry stands in for an unreadable drive; anything else is fetched from R2 (200 a run, never metered). A short listing is refused (10% shrink guard). Roots come from `masters_roots` on the M2. An unreadable root, or one busy for 20 min (the TV in use), is a warning in `push-status.json` and a WARN row in media-sync, never a failed push. |
| 2 Alias table | `music/ids.json`, built in the same run (`musicstore.build_ids`) | `key` (embed.match_key `artist\|title`), `isrc`, `path`, `apple`, `persistent`, `youtube`, `how`, `collisions`. A shared key keeps a stable sha (the one chosen before, else the earliest added). Claims come from `alias-inputs/*.jsonl` on the M2: the TV's music-video file names (`youtube_dirs`) and the M5's scout ledger, favourites pull and library copy (copied over by `push-kick.sh`). Readers: `radio_sync` sends `s` (sha) with each event, and the TV looks vectors up by sha (YouTube id, then the key). Fuzzy matching stays as the fallback and is counted. `match-key-fixture.json` keeps the JS mirror (`embedMatchKey`) honest. |
| 3 Taste log | `music/taste/<listener>/<YYYY-MM>/<app>-<host>.jsonl`; `musicstore.py append` | Events `{at, listener, app, host, kind, sha\|alias, fraction, id}`; kinds play, finish, skip, early-skip, like, unlike, dislike, undislike, heart, unheart, more, less. Local spool, then `flush`; one writer per object; deterministic ids. Glancebar: `radio_sync` tails feedback, skips, hearts and plays (listener `ian`), so the app does not yet call the log itself. TV: music-video likes, `household-tv` unless `musicTasteListeners` maps a lone viewer. 6IAN: `import-radio` on the M2 derives each mapped account's own events (`radio_accounts` in `music-store.json`). |
| 4 One acquisition queue (scout side) | `tools/music-scout` `acquire_via: lane` | The scout hands its ranked picks to the lane inbox on the M2 and no longer acquires with amdl or keeps a budget (M5 config switched 19 Nov). |
| 5 Facts | `music/facts.json`; `tools/music-store/facts.py` | One record per sha: MusicBrainz year (years.py rules ported; the radio's `data/years.json` seeds it), cover keys, LRCLIB lyrics id, Wikipedia page. 1,500 requests a night (22:30Z, M2), resumable. Readers: `musicstore.py pull` (both Macs) and `radio_sync about`. |

Jobs: `com.iantodd.glancebar-music-push` (M5, now runs `push-kick.sh`), `com.iantodd.music-store-sync` (M2,
every 10 min), `com.iantodd.music-facts` (M2, 22:30Z). Config per Mac: `~/.config/glancebar/music-store.json`.

**Landed 20 Nov 2026 (streamlining & 6IAN adoption):**
1. **Shared backend extracted to `~/Projects/music-core`** (`store/`, `library/`, `embed/`, `discovery/`, `media_sync/`, `mixpool/`, `pipeline/`, `.fleet/check`). Glancebar, 6IAN, and Onto the TV are now thin front-ends reading the unified store; Glancebar keeps fallback copies in `tools/` only so standalone GitHub Actions CI stays green.
2. **6IAN (`music-radio`) adopted all 5 unification interfaces**: `/api/device/signals` accepts `x.s` (sha), `lib/match.ts` resolves via `music/ids.json` (`embedMatchKey`), `lib/space.ts` + `/api/info/[sha]` read `music/facts.json` (retiring `tools/years.py` from nightly rebuild), `/api/event` appends real events directly to `music/taste/<listener>/<YYYY-MM>/6ian-vercel.jsonl` via ETag CAS (dropping `import_radio` on M2), and `media/place_masters.py` dropped the legacy `stash-not-in-r2` / `def _roots` hold.
3. **Chained M2 nightly pipeline (`com.iantodd.music-core-nightly`, 19:40Z via `ssh localhost`)**: replaces the M5→M2 SSH-kick jobs (`glancebar-music-push`, `glancebar-music-embed`) and standalone `music-facts` with one sequenced hub run (`push → embed → mirror-vectors → facts → check`). `com.iantodd.music-core-place` (M2, every 15m) replaces M5→M2 `music-radio-place`. `com.iantodd.music-core-m5-sync` (M5, every 4h) handles alias claims, vector pull/export, and Glancebar's lossless hot-set sync.
