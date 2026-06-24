// Glancebar — pure, dependency-light logic (Foundation only), shared by the app and
// the unit tests. No AppKit, no IOKit, no I/O: deterministic given its inputs.
#import <Foundation/Foundation.h>
#import <sys/types.h>

typedef struct {
    BOOL valid;
    int  percent;          // 0..100
    BOOL isCharging;
    BOOL acConnected;
    BOOL fullyCharged;
    long rawCurrent_mAh;
    long rawMax_mAh;
    long designCap_mAh;
    long amperage_mA;      // negative = discharging
    long voltage_mV;
    long cycleCount;
    long minutesToEmpty;   // macOS-smoothed; <=0 = invalid
} BatteryState;

// Minutes until 20%, or -1 if not estimable (charging / settling / already ≤20%).
int MinutesTo20(BatteryState b, double avgAmp_mA);

// "h:mm", or "estimating…" for minutes < 0.
NSString *FmtDuration(int minutes);

// Parse `top -l 2 …` output: keep the SECOND "PID … POWER" frame, sum each process's
// energy impact into a group (groupForPid(pid) ?: the command token), and preserve the
// raw command names under @"commands". Returns the top-N groups sorted by impact:
// @[@{@"name":…, @"impact":@(…), @"totalImpact":@(…), @"commands":@[…]}].
NSArray<NSDictionary *> *ParseHogs(NSString *topOutput, int topN,
                                   NSString *(^groupForPid)(pid_t));

// --- Codex rollout parsing ---
// Codex CLI writes per-session JSONL rollouts (~/.codex/sessions/YYYY/MM/DD/*.jsonl,
// moving to ~/.codex/archived_sessions/ on archive). Each turn logs a token_count
// event whose last_token_usage is a verified per-turn delta, alongside the official
// rate-limit gauges. These are the only accurate per-day usage source: the sqlite
// threads.tokens_used column is a lifetime counter and cannot be windowed.

// Parses one rollout line. Returns nil unless it is a token_count event:
// @{@"ts": ISO-8601 string, @"tokens": @(per-turn total incl. cached context re-reads),
//   @"fresh": @(non-cached input + output — the humanly meaningful count),
//   @"limits": rate_limits dict (optional)}
NSDictionary *ParseTokenCountLine(NSString *line);

// Buckets parsed events into per-local-day totals, merged over existingDays.
// Returns @{@"days": @{@"yyyy-MM-dd": @{@"t": total, @"f": fresh}}, and when any event
// carried limits, @"latestLimits": rate_limits dict, @"latestTs": its ISO timestamp}.
NSDictionary *AccumulateTokenEvents(NSDictionary<NSString *, NSDictionary *> *existingDays,
                                    NSArray<NSDictionary *> *events, NSTimeZone *tz);

// Parses one Claude Code transcript line (~/.claude/projects/**/*.jsonl). Returns nil
// unless it is an assistant message carrying usage. Anthropic semantics: input_tokens
// is already non-cached, so fresh = input + output and the all-inclusive total adds
// cache_creation + cache_read. Shape:
// @{@"ts": ISO-8601 string, @"tokens": @(all-inclusive), @"fresh": @(input+output),
//   @"id": message id when present (for duplicate-line dedupe)}
NSDictionary *ParseClaudeUsageLine(NSString *line);

// Picks the most constrained, still-current window from a Codex rate_limits dict
// (primary = 5h, secondary = weekly; resets_at is epoch seconds — windows whose reset
// has passed are obsolete and skipped). Returns nil when none is current, else
// @{@"remainingFraction": @(0..1), @"window": @"5-hour"/@"weekly"/…,
//   @"resetsAt": @(epoch) (optional), @"plan": plan string (optional)}.
NSDictionary *PickLimitWindow(NSDictionary *rateLimits, double nowEpoch);

// Picks the most constrained, still-current window from Anthropic's OAuth usage
// response (window dicts like five_hour/seven_day carrying utilization + resets_at).
// Tolerates fraction or percent utilization and ISO-8601 or epoch resets_at. Returns
// nil when nothing is current, else the same shape as PickLimitWindow.
NSDictionary *PickClaudeLimitWindow(NSDictionary *usage, double nowEpoch);

// ALL still-current limit windows (for the dual-meter breakdown), in fixed reading
// order rather than most-constrained-first: Codex primary→secondary, Claude
// 5-hour→weekly→weekly Opus (weekly Sonnet is intentionally not surfaced). Obsolete
// (reset-elapsed) windows and the Claude extra_usage credit budget are excluded. Each
// element has the same shape as PickLimitWindow. Empty array when none apply. (The bar's
// single gauge still uses the Pick*LimitWindow pickers above; these feed the
// popover/details breakdown.)
NSArray<NSDictionary *> *CodexLimitWindows(NSDictionary *rateLimits, double nowEpoch);
NSArray<NSDictionary *> *ClaudeLimitWindows(NSDictionary *usage, double nowEpoch);

// Reads Anthropic's extra_usage credit budget. Returns nil when absent/disabled, else
// @{@"description": display string, @"statusReason": short status,
//   @"overageActive": @(YES when usage is at/over the paid limit)}.
NSDictionary *ClaudeExtraUsageStatus(NSDictionary *usage);

// Claude account fetches are gated by visibility, but a newly visible UI with no
// cached account state must fetch even if an older retry timer is in the future.
BOOL ShouldFetchClaudeAccount(BOOL useAccount, BOOL allowFetch, BOOL hasUsageJSON,
                              BOOL hasAccountStatus, double nowEpoch, double nextFetchEpoch);

// Seconds until the next account fetch after a 429: at least the standard 15-minute
// throttle, but never trust a server-supplied Retry-After beyond an hour.
double RateLimitRetryDelay(double retryAfterSeconds);

// An auth failure means the cached access token is dead (e.g. Claude Code re-login
// revoked it); drop it so the next attempt re-reads the Keychain.
BOOL ShouldDropCachedTokenForStatus(NSInteger statusCode);

// Classifies a Keychain credential read. Missing/denied/empty backs off an hour (each
// retry may prompt the user); an expired token retries in 5 minutes (Claude Code
// refreshes it quickly, and re-reading an item we already have ACL access to never
// prompts). Returns @{@"ok": @YES, @"token":, @"expiresAt":} or
// @{@"ok": @NO, @"status": display string, @"retryDelay": @(seconds)}.
NSDictionary *ClaudeKeychainOutcome(BOOL itemFound, NSString *token,
                                    double expiresAtEpoch, double nowEpoch);

// The user-facing reason when PickLimitWindow shows no Codex gauge: nil when a window
// is current (caller shows the gauge), "do not carry" only when no usable rate_limits
// were ever seen, and an explicit stale message when every usable window has already
// reset (dated from the snapshot's ISO-8601 timestamp when parseable).
NSString *CodexLimitStatusReason(NSDictionary *rateLimits, NSString *limitsTs, double nowEpoch);

// Parse `ps -axo pid=,pcpu=,rss=,comm=` output into grouped top CPU and memory apps.
// bytesForPid (optional) supplies a per-pid physical footprint; when nil or returning 0
// the row falls back to RSS*1024 (which double-counts shared pages across helpers). Shape:
// @{@"cpu": @[@{@"name":…, @"cpu":@(…), @"bytes":@(…), @"commands":@[…]}],
//   @"memory": @[…]}.
NSDictionary<NSString *, NSArray<NSDictionary *> *> *ParseProcessStats(NSString *psOutput, int topN,
                                                                        NSString *(^groupForPid)(pid_t),
                                                                        unsigned long long (^bytesForPid)(pid_t));
