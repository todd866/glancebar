# Codex allowance freshness

Glancebar refreshes quota through the installed Codex CLI's public app-server
`account/rateLimits/read` method every five minutes. It uses the CLI's existing
sign-in; Glancebar does not read, copy, or store its credentials. The app-server
child runs on the AI queue, opens no windows, and is terminated after the response
or a 15-second timeout. No model turn is generated.

The background app permits these reads unless Low Data is enabled. CLI diagnostics
remain local-only unless `--online` is supplied. If the CLI is missing, signed out,
or unable to read account state, the refresh error is exposed and local session
observations remain available as fallback. The CLI must be signed into the account
whose allowance you want to monitor.

Live snapshots are persisted separately from the session index, so a log rescan
cannot erase them. Offline diagnostics and the running app preserve newer shared
snapshots. Per-day token and activity totals still come from local logs; account
quota and local activity are different readings.

A limit observation is current for at most 15 minutes and only until its reset.
This age is measured from the observation itself, never the cache's write time.
Missing or future timestamps cannot establish current capacity. When both sources
stop, the compact row shows `—` and `stale <age>`; an unknown timestamp shows
`unavailable`. No stale gauge fill or percentage remains.

Each window keeps its own observation time. A fresh model-specific bucket does
not refresh the general plan allowance. Paid credits have independent freshness:
zero paid credits do not mean the plan allowance is exhausted. The CLI dump's
headline percentage becomes null when Codex capacity is unavailable.

Protocol mapping is covered by `Tests/test_ai_reader.m`, including no local logs,
separate plan/model buckets, offline reads, polling, persistence, failed refreshes,
and malformed responses.
