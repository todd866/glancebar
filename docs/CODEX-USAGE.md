# Codex allowance freshness

The Codex row reads rate-limit observations recorded in local Codex session logs.
It does not query the desktop app's private state or reuse a chat's account tool.
Work on another Codex surface may therefore leave the local logs unchanged.

A limit observation is current for at most 15 minutes and only until its reset.
This age is measured from the observation itself, never the reader cache's write
time. Missing or future timestamps cannot establish current capacity. When the
source stops, the compact row shows `—` and `stale <age>`; an unknown timestamp
shows `unavailable`. No stale gauge fill or percentage remains. A fresh local
observation restores the normal row automatically.

Each window keeps its own observation time. A fresh model-specific bucket does
not refresh the general plan allowance. A fresh general plan window can display
while an older sibling is unavailable. Paid credits have independent freshness:
zero paid credits do not mean the plan allowance is exhausted. The CLI dump's
headline percentage also becomes null when Codex capacity is unavailable;
historical window records retain their observation timestamps for diagnostics.

OpenAI documents `account/rateLimits/read` in its
[app-server API](https://learn.chatgpt.com/docs/app-server#auth-endpoints).
This build does not add an account connection or credential access. Until a
supported fresh source is configured, a stale local observation stays visibly
unavailable rather than being represented as current.
