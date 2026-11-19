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
