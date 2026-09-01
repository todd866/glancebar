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
// ALL still-current Codex limit windows for the dual meter (primary→secondary).
NSArray<NSDictionary *> *CodexLimitWindows(NSDictionary *rateLimits, double nowEpoch);

// Folds a newly-seen rate_limits snapshot onto what is already known: the newest
// snapshot supplies the scalars, and the primary/secondary pair comes — as a pair —
// from whichever snapshot last carried one.
//
// Codex sends `"primary": null` once requests are billed to a different bucket — the
// weekly allowance runs out under limit_id "codex" and the next snapshot arrives under
// "premium" with both windows null. Taking the newest snapshot wholesale therefore
// erases the only record of when that allowance returns, exactly when the user most
// wants to know. A retained window expires on its own resets_at, so carrying it forward
// cannot outlive its truth. Each meter is stamped with the snapshot it came from, so a
// carried-forward window can still say how old it is.
//
// Order-independent: fold snapshots in any sequence and the result is the same. Equal
// stamps are resolved toward the reading that claims LESS quota left, so an arbitrary
// enumeration order can never be the difference between reporting room and reporting
// none. CONTRACT: each (snapshot, ts) pair must belong together — a meter is stamped
// with the ts it is folded under, and that stamp then travels with it.
NSDictionary *MergeCodexRateLimits(NSDictionary *kept, NSString *keptTs,
                                   NSDictionary *incoming, NSString *incomingTs);

// Reads the `credits` object that newer Codex builds send beside the windows. Returns
// nil when absent, else @{@"exhausted": @(nothing left to spend), @"unlimited": @(...),
//   @"balance": balance string when present, @"description": display string,
//   @"observedAt": ISO-8601 stamp when the meter was carried forward}.
//
// NOT a substitute for the windows: this account reported has_credits=false with a
// zero balance for days while the weekly window still had room and Codex answered
// normally. A zero balance means "no credit balance to fall back on", never "refused" —
// only an exhausted window means that. Report it as context, never as the gauge.
NSDictionary *CodexCreditsStatus(NSDictionary *rateLimits);

// Names a rate_limits snapshot Glancebar cannot read, so schema drift reports itself
// instead of hiding behind "no limit status". Nil while the snapshot makes sense.
//
// Two things must not be confused. A snapshot that says `"primary": null` is UNDERSTOOD
// and empty — that is Codex's normal way of saying an allowance is not being metered
// right now, and it must stay silent. Drift is a snapshot that carries no readable meter
// AND either a window object whose insides changed (a dict with no numeric used_percent)
// or top-level keys this build has never heard of.
//
// This distinction is the whole point: Glancebar spent a day telling its user "Codex
// session logs do not carry limit status" when the logs carried it fine and only the
// selection was wrong. An app that cannot read its source should say so in those words.
NSString *CodexSchemaDriftReason(NSDictionary *rateLimits);

// Picks the most constrained, still-current window from Anthropic's OAuth usage
// response (window dicts like five_hour/seven_day carrying utilization + resets_at).
// Anthropic defines utilization as a percentage (so 1.0 means 1%, not 100%); resets_at
// may be ISO-8601 or epoch. Unknown and reset-less placeholder windows are excluded.
// Returns nil when nothing is current, else the same shape as PickLimitWindow.
NSDictionary *PickClaudeLimitWindow(NSDictionary *usage, double nowEpoch);
// ALL still-current Claude limit windows (5-hour→weekly→weekly Opus; weekly Sonnet is
// never surfaced). Obsolete/reset-less/unknown windows and extra_usage are excluded.
NSArray<NSDictionary *> *ClaudeLimitWindows(NSDictionary *usage, double nowEpoch);

// Elapsed known Claude windows only (same keys/labels as ClaudeLimitWindows). Used when
// the live set is empty so the UI can keep showing last-known % + reset. Reset-less
// placeholders and unknown buckets stay excluded. Empty when nothing elapsed.
NSArray<NSDictionary *> *ClaudeStaleLimitWindows(NSDictionary *usage, double nowEpoch);
// Most recently expired window from ClaudeStaleLimitWindows (highest resetsAt). Nil when
// the stale set is empty.
NSDictionary *PickClaudeStaleLimitWindow(NSDictionary *usage, double nowEpoch);
// Nil while any live Claude window remains; dated "reset since last Claude refresh" when
// every known window has elapsed; otherwise the missing-window fallback string.
NSString *ClaudeLimitStatusReason(NSDictionary *usage, NSString *fetchedAtISO, double nowEpoch);

// Picks the current Cursor included-quota window from either GetCurrentPeriodUsage
// (planUsage spend in cents + billingCycleEnd) or legacy GET /auth/usage (per-model
// request buckets). Same output shape as PickLimitWindow. planUsage wins when both
// shapes are present. Returns nil when nothing usable/current remains.
NSDictionary *PickCursorLimitWindow(NSDictionary *usage, double nowEpoch);
// All current Cursor windows for the dual meter (usually one). Empty when none apply.
NSArray<NSDictionary *> *CursorLimitWindows(NSDictionary *usage, double nowEpoch);

// Elapsed Cursor windows (billing cycle ended, or auth buckets with a past cycle marker).
// Same role as ClaudeStaleLimitWindows. Empty when nothing elapsed-and-usable remains.
NSArray<NSDictionary *> *CursorStaleLimitWindows(NSDictionary *usage, double nowEpoch);
NSDictionary *PickCursorStaleLimitWindow(NSDictionary *usage, double nowEpoch);
NSString *CursorLimitStatusReason(NSDictionary *usage, NSString *fetchedAtISO, double nowEpoch);

// Reads Anthropic's extra_usage credit budget. Returns nil when absent/disabled, else
// @{@"description": display string, @"statusReason": short status,
//   @"overageActive": @(YES when usage is at/over the paid limit)}.
NSDictionary *ClaudeExtraUsageStatus(NSDictionary *usage);

// --- AI status line ---
// The popover's AI row has one job: say when the quota comes back. Format the reset the
// way a reader thinks about it — a clock time, plus a countdown while the window is near
// enough to plan around — and let the plumbing diagnostics live in the details sheet.
//   "Resets 9:12 pm · in 3h 20m" / "Resets tomorrow 9:00 am · in 14h"
//   "Resets Wed 9:00 am · in 4d"  / "Resets 3 Sep, 10:24 pm · in 11d"
// A reset already in the past means the cached window rolled over unseen, so it reports
// that plainly ("Reset has passed") and leaves the age of the figure to the caller.
// Nil when there is no reset instant at all.
NSString *ResetPhrase(NSDate *resetAt, NSDate *now);
// Just the "when" half — "9:12 pm" / "tomorrow 9:00 am" / "Wed 9:00 am" / "3 Sep, 10:24 pm"
// — for surfaces that already say what is resetting, like the dual-meter card. Nil for a
// nil date; unlike ResetPhrase it will happily format an instant that has already passed.
NSString *ResetClockText(NSDate *resetAt, NSDate *now);

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

// Reads the SleepDisabled system power setting from `pmset -g` output: @YES when the Mac
// is set to stay awake with the lid closed, @NO when normal, or nil when the line is
// absent (state unknown). Parses text only — no I/O. Writing the setting needs root and
// lives in the app shell; reading it does not.
NSNumber *ParseSleepDisabled(NSString *pmsetOutput);

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

// macOS 26 can permanently attribute an NSStatusItem to the terminal/host app when a
// GUI executable is started directly instead of through Launch Services. The running
// application identifier is present on a normal Finder/open/login-item launch and must
// match the app's own bundle identifier before the controller creates its status item.
BOOL GUIRequiresLaunchServicesRelaunch(NSString *runningBundleID,
                                      NSString *expectedBundleID);

// --- Adaptive bar width ---
// The menu bar item renders at one of three tiers; macOS evicts an item wholesale
// when it cannot fit beside the notch, so Glancebar sizes itself to what exists.
// Compact keeps the most useful configured reading rather than erasing all text.
enum { BarTierFull = 0, BarTierCompact = 1, BarTierGlyph = 2 };

typedef struct {
    int tier;             // current rendering tier (BarTier*)
    int expandStreak;     // consecutive decisions the next-wider tier fit with slack
    double lastCountedAt; // epoch of the last counted decision (rate-limits the streak)
} BarTierState;

// Hysteresis: shrink the moment the current tier doesn't fit (small margin);
// expand one tier per decision, only after kBarExpandTicks consecutive decisions
// where the wider tier fit with kBarExpandMarginPt of slack — transient menu bar
// churn (AirPods connect, Now Playing) can shrink us but cannot bounce us.
extern const double kBarShrinkMarginPt;   // 4
extern const double kBarExpandMarginPt;   // 8
extern const int    kBarExpandTicks;      // 2
// updateBar fires from many uncoordinated sources (15s timer, IOPS bursts, volume
// scans, appearance changes), so a "consecutive decisions" streak alone can be
// satisfied in milliseconds. Counted decisions must be spaced in wall-clock time or
// the anti-flap guarantee is decisions-shaped, not time-shaped.
extern const double kBarExpandMinIntervalSec;   // 10

// gapPt: measured free points beside the notch, < 0 = unmeasurable (hold tier).
// widths[]: this tick's rendered width of each tier. evicted: the shell saw the
// item's window parked off the bar — forces glyph regardless of the measurement,
// which is by definition stale when eviction has already happened.
// nowEpoch: monotonic-ish wall clock used only to rate-limit streak counting.
BarTierState ChooseBarTier(BarTierState prev, double gapPt,
                           const double widths[3], BOOL evicted, double nowEpoch);
