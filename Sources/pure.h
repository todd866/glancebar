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
// Each day is @{@"t": total, @"f": fresh, @"n": events, @"c": tool calls (when any),
//   @"m": @{model: fresh} (when events name a model)} — see MergeDayCounts.
// Returns @{@"days": {...}}, and when any event carried limits: @"latestLimits" (the
// legacy cross-bucket merge), @"latestTs", @"buckets" (per-limit_id map, see
// FoldCodexSnapshotIntoBuckets), @"newestLimits" (the newest snapshot verbatim, for the
// drift check) and @"newestTs".
NSDictionary *AccumulateTokenEvents(NSDictionary<NSString *, NSDictionary *> *existingDays,
                                    NSArray<NSDictionary *> *events, NSTimeZone *tz);
// Sums two per-day counter dicts (t/f/n/c and the per-model map m). Either may be nil.
NSDictionary *MergeDayCounts(NSDictionary *a, NSDictionary *b);

// Parses one Claude Code transcript line (~/.claude/projects/**/*.jsonl). Returns nil
// unless it is an assistant message carrying usage. Anthropic semantics: input_tokens
// is already non-cached, so fresh = input + output and the all-inclusive total adds
// cache_creation + cache_read. `usage.iterations[]` restates the same numbers and is
// ignored. Shape:
// @{@"ts": ISO-8601 string, @"tokens": @(all-inclusive), @"fresh": @(input+output),
//   @"id": message id when present (for duplicate-line dedupe),
//   @"model": model id when present, @"tools": @(tool_use content blocks) when any}
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
// response. Since 2026-09 the response carries a `limits` array (kind session /
// weekly_all / weekly_scoped with `percent`, `resets_at`, `is_active`, and a model scope
// naming the scoped weekly, e.g. "Fable"); the legacy five_hour/seven_day/seven_day_opus
// dicts (utilization + resets_at) are read only when the array is absent or unreadable.
// Anthropic reports utilization/percent as a PERCENTAGE (1.0 means 1%, not 100%);
// resets_at may be ISO-8601 or epoch. Returns nil when nothing is current, else the same
// shape as PickLimitWindow (plus @"kind"/@"active" from the array, and @"fresh": @YES for
// an unused window — see ClaudeLimitWindows).
NSDictionary *PickClaudeLimitWindow(NSDictionary *usage, double nowEpoch);
// ALL still-current Claude limit windows in source order (5-hour→weekly→scoped weeklies;
// legacy weekly Sonnet is never surfaced). Obsolete windows and extra_usage are excluded.
// A reset-less window with nothing used is a FRESH window (100% left, starts on first
// use) and is surfaced only when every readable window is fresh — the state a new week
// begins in, which used to read as "no current limit window". Otherwise reset-less
// entries are placeholders (an unused model-scoped weekly) and stay hidden.
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

// Reads Anthropic's extra_usage credit budget. Returns nil when absent, else
// @{@"description": display string, @"statusReason": short status,
//   @"overageActive": @(YES when usage is at/over the paid limit)}. A disabled budget
// returns only a description ("Off · out of credits") so Details can say why the
// account has no overage to fall back on; it carries no statusReason and no overage.
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

// Seconds until the next account fetch after a 429. A server-supplied Retry-After is
// honoured within [60, 3600]. Without one, the wait starts at two minutes and doubles
// per consecutive 429 (streak = 1 for the first), never beyond the 15-minute poll
// interval: the usage endpoint 429s transiently, and a single miss used to leave a
// freshly opened popover on a figure hours old.
double RateLimitRetryDelay(double retryAfterSeconds, NSUInteger consecutive429s);

// A cached account snapshot older than two poll intervals is not a figure a refresh
// would have reproduced; the row should say so in colour, not only in its caption.
BOOL StaleSnapshotWarns(double ageSeconds, double pollIntervalSeconds);

// The per-model weekly figures for the popover's Fable / Opus row, from
// ClaudeLimitWindows output. Nil when no model-scoped weekly window is present.
// Keys: fable, opus (remaining fractions, -1 when not reported); fableWindow,
// opusWindow (the governing window dicts, absent when nothing governs); fableShared,
// opusShared (YES when that model has no window of its own and is governed by the
// account-wide weekly instead — the Claude app shows "Current week (all models)" beside
// "Current week (Fable)", and Opus falls under the former); resetsAt (the weekly reset,
// when known). The account-wide weekly caps both figures; the 5-hour window never does —
// it is a different clock and lives in the caption.
NSDictionary *ClaudeModelQuotas(NSArray<NSDictionary *> *windows);

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

// --- Codex limit buckets ---
// Codex meters several allowances at once, each under its own `limit_id`, and one
// session's snapshots alternate between them turn by turn: "codex" (the plan allowance),
// "codex_<name>" side buckets, and "premium" once requests bill to credits. Folding them
// into one rate_limits dict let whichever bucket reported LAST stand in for all of them:
// on 2026-09-07 an untouched side bucket (0% used, newest by seconds) hid a plan weekly
// window at 99% used, and the app read "100% left" while the plan was spent until
// Saturday. Buckets are therefore kept apart and only compared, never blended.
//
// A bucket map is @{limit_id: @{@"limits": merged rate_limits, @"ts": newest ISO ts}}.
// Within a bucket MergeCodexRateLimits' rules still apply (the window pair moves
// together, is stamped, and expires on its own resets_at).
NSString *CodexLimitBucketID(NSDictionary *rateLimits);          // limit_id, "codex" when absent
NSString *CodexBucketLabel(NSString *bucketID);                  // "plan" / "credits" / "<name>"
NSDictionary *FoldCodexSnapshotIntoBuckets(NSDictionary *buckets, NSDictionary *snapshot, NSString *ts);
NSDictionary *MergeCodexLimitBuckets(NSDictionary *a, NSDictionary *b);   // order-independent union
NSString *CodexNewestBucketID(NSDictionary *buckets);            // the bucket requests bill to now
NSDictionary *CodexNewestBucketLimits(NSDictionary *buckets);
// Every still-current window across buckets, each tagged @"bucket" and @"bucketLabel".
// The bucket with the least room comes first (ties: the newer snapshot), primary before
// secondary within a bucket — the order the dual meter draws them in.
NSArray<NSDictionary *> *CodexBucketWindows(NSDictionary *buckets, double nowEpoch);
// The most constrained current window across buckets: never grant room one bucket
// reports while another says the allowance is spent. Same shape as PickLimitWindow
// plus @"bucket"/@"bucketLabel".
NSDictionary *PickCodexBucketWindow(NSDictionary *buckets, double nowEpoch);
// CodexLimitStatusReason across buckets: nil while any bucket has a current window.
NSString *CodexBucketsStatusReason(NSDictionary *buckets, double nowEpoch);
// Says where requests bill when that is not the bucket whose window is shown —
// "Requests now bill to credits · none available" — else nil.
NSString *CodexBillingNote(NSDictionary *buckets, double nowEpoch);

// The human name for an executable path: its basename, unless that is a bare version
// number — Claude Code's native install runs `.../claude/versions/2.1.261`, and "2.1.261"
// is no name — in which case the first component above it that reads as one.
NSString *ProcessNameFromPath(NSString *executablePath);

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
// The menu bar item renders at one of four tiers; macOS evicts an item wholesale when
// it cannot fit beside the notch, so Glancebar sizes itself to what exists. The rungs
// give up as little as possible at each step: the icons go before any reading does, and
// a single reading survives before the item becomes a bare glyph.
//   Full     💾 61%  🔋 76%   every configured reading, with its meter icons
//   Text     61%  76%         the same readings, no icons (~30% narrower)
//   Compact  76%             the one reading marked compactPriority (battery percentage)
//   Glyph    ⌾                identity only
// The lid-awake eye is a safety reminder, not decoration: it survives every tier.
enum { BarTierFull = 0, BarTierText = 1, BarTierCompact = 2, BarTierGlyph = 3 };
#define kBarTierCount 4

typedef struct {
    double x;
    double width;
} BarWindowSpan;

// Points our live item may occupy as the status hosts to its left shift into free
// space. leftBoundary is the notch/screen edge or the end of the fixed app menus;
// spans contains only movable status hosts. Count overlapping/duplicate hosts once.
// Control Centre's visible copy can have a different window number from the app-side
// NSWindow, so exclude substantially overlapping self spans by geometry. A neighbour
// actually intruding into our frame still limits capacity until the layout settles.
double BarCapacityFromWindowSpans(double leftBoundary, double rightEdge,
                                  BarWindowSpan own,
                                  const BarWindowSpan *spans, size_t count);

typedef struct {
    int tier;             // current rendering tier (BarTier*)
    int expandStreak;     // consecutive decisions the next-wider tier fit with slack
    double lastCountedAt; // epoch of the last counted decision (rate-limits the streak)
} BarTierState;

// Hysteresis: shrink only when the current tier no longer fits at all (an item that
// is on the bar already fits — a neighbour packed against its left edge leaves exactly
// zero slack, and that is the normal Control Centre layout, not a squeeze); the tier we
// shrink TO must fit with kBarShrinkMarginPt of slack. Expand one tier per decision,
// only after kBarExpandTicks consecutive decisions where the wider tier fit with
// kBarExpandMarginPt of slack — transient menu bar churn (AirPods connect, Now Playing)
// can shrink us but cannot bounce us.
extern const double kBarFitTolerancePt;   // 1 — compositor rounding on the measured span
extern const double kBarShrinkMarginPt;   // 4
extern const double kBarExpandMarginPt;   // 8
extern const int    kBarExpandTicks;      // 2
// updateBar fires from many uncoordinated sources (15s timer, IOPS bursts, volume
// scans, appearance changes), so a "consecutive decisions" streak alone can be
// satisfied in milliseconds. Counted decisions must be spaced in wall-clock time or
// the anti-flap guarantee is decisions-shaped, not time-shaped.
extern const double kBarExpandMinIntervalSec;   // 10

// capacityPt: measured physical points the current status-item host may occupy while
// growing left, < 0 = unmeasurable (hold tier). widths[]: this tick's physical host
// width for each tier (rendered image plus shell chrome), widest first. evicted: the
// shell saw the item's window parked off the bar — forces glyph regardless of the
// measurement, which is by definition stale when eviction has already happened.
// nowEpoch: monotonic-ish wall clock used only to rate-limit streak counting.
BarTierState ChooseBarTier(BarTierState prev, double capacityPt,
                           const double widths[kBarTierCount], BOOL evicted, double nowEpoch);

// Eviction is a fall FROM the bar, so the net arms only after the item has been seen
// there — except that an item launched into an already-crowded bar is never seen at
// all, and would hold its (invisible) full tier for the whole session. After
// kBarEvictionGraceSec without a sighting, "not on the bar" counts as evicted: the
// glyph is drawn, Control Centre places it, and measurement-gated expansion takes it
// back up within a couple of ticks if there was room after all.
//
// barObservable is the whole safeguard on that inference. With the lid closed (or the
// display otherwise asleep) the window list reports nothing for this process's own
// windows, which is indistinguishable from having been evicted — and nobody can see the
// bar anyway, so there is nothing to decide. Absence of evidence is not eviction: when
// the bar cannot be observed this returns NO and the caller holds its tier until the
// display comes back and a real measurement is possible.
extern const double kBarEvictionGraceSec;   // 30
BOOL BarEvictionSuspected(BOOL barObservable, BOOL seenOnBar, BOOL onBar, double sinceCreatedSec);
