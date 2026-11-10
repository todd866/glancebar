# Scale / crash branch notes (gb-crash-fix)

## Stale coverage cache (2026-11-10)

**Symptom:** `Tests/test_offline.m` — after overwriting a playlist file, `playOfflinePlaylist:` still saw `ready` from `_offlineCoverageCache` (keyed only on request generation + manifest hash).

**Fix:** Store disk fingerprints (size, inode, mtimeNs) for manifest record paths alongside cached coverage; revalidate fingerprints on each cache hit before returning cached coverage.

## Playback harness (ASan+UBSan, 2026-11-10, M5 worktree)

Prior WIP crash fix (commit `9787b31`) was **not** amended; this worker only re-ran the harness after the coverage fix.

Three consecutive `tools/check-playback.m` builds with `-fsanitize=address,undefined` (same flags as `GLANCEBAR_TEST_SANITIZERS=1` in `tests.sh`):

| Run | First-audio latency (2k uniform paths) | Worst main-thread stall |
|-----|----------------------------------------|-------------------------|
| 1   | 5 ms                                   | 2.0 ms                  |
| 2   | 5 ms                                   | 2.0 ms                  |
| 3   | 3 ms                                   | 1.9 ms                  |

All exited 0, printed `OK: playback harness scenarios passed`. Targets: &lt;1500 ms start, &lt;250 ms stall — met with large margin.

No new SIGSEGV; no sanitizer reports.

## Harness / UI follow-ups (same session)

- `rebuildContent` skip: require `_musicOff` as well as `_mixFrozen` so `check-popover.m` (frozen mix, music on) still builds the tree.
- Restored System output accessibility label (`Player output, System, <device>`).
- `libraryRefreshPump` loops through synchronous legs when cache prepare returns immediately (no bundled helper).
- `test_music_library_storm.m` on this M5 failed with live `~/.local/state/METERED_LINK` present (`metered=1` blocks sync). Passed with `GLANCEBAR_HOME`/`HOME` isolated temp dir (as `tests.sh` layout on CI/M2 without that file).
