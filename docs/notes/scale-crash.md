# Scale / crash branch notes (gb-crash-fix)

## Stale coverage cache (2026-11-10)

**Symptom:** `Tests/test_offline.m` — after overwriting a playlist file, `playOfflinePlaylist:` still saw `ready` from `_offlineCoverageCache` (keyed only on request generation + manifest hash).

**Fix:** Store disk fingerprints (size, inode, mtimeNs) for manifest record paths alongside cached coverage; revalidate fingerprints on each cache hit before returning cached coverage.
