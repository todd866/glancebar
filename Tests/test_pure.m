// Unit tests for Glancebar's pure functions (Sources/pure.m). Run via ./tests.sh.
#import <Foundation/Foundation.h>
#import "pure.h"

static int failures = 0;
static void check(BOOL cond, NSString *msg) {
    fprintf(stderr, "%s %s\n", cond ? "ok  " : "FAIL", msg.UTF8String);
    if (!cond) failures++;
}

int main(void) {
    @autoreleasepool {
        // --- MinutesTo20 ---
        check(MinutesTo20((BatteryState){.acConnected=YES, .percent=90, .minutesToEmpty=300}, -500) == -1, @"AC connected → -1");
        check(MinutesTo20((BatteryState){.isCharging=YES, .percent=50, .minutesToEmpty=200}, -500) == -1, @"charging → -1");
        check(MinutesTo20((BatteryState){.percent=20, .minutesToEmpty=60}, -500) == -1, @"already 20% → -1");
        check(MinutesTo20((BatteryState){.percent=100, .minutesToEmpty=200}, 0) == 160, @"100%, 200min→empty ⇒ 160min→20%");
        check(MinutesTo20((BatteryState){.percent=60, .minutesToEmpty=120}, 0) == 80, @"60%, 120min→empty ⇒ 80min→20%");
        check(MinutesTo20((BatteryState){.percent=80, .minutesToEmpty=-1, .rawCurrent_mAh=4000, .rawMax_mAh=5000}, -1000) == 180,
              @"fallback amperage ⇒ 180min→20%");

        // --- ParseHogs grouping ---
        NSString *sample =
            @"Processes: 1\nPID    COMMAND          POWER\n1      WindowServer     0.0\n"
             "Processes: 1\nPID    COMMAND          POWER\n"
             "101    Chrome Helper    20.0\n102    Chrome Helper    15.0\n"
             "103    WindowServer     26.7\n104    iTerm2           4.0\n";
        NSArray *hogs = ParseHogs(sample, 5, ^NSString *(pid_t pid) {
            return (pid == 101 || pid == 102) ? @"Google Chrome" : nil;
        });
        check(hogs.count == 3, @"3 groups after rollup");
        check([hogs[0][@"name"] isEqual:@"Google Chrome"], @"Chrome top after rollup (20+15=35)");
        check([hogs[0][@"impact"] doubleValue] == 35.0, @"Chrome helpers summed to 35");
        check(fabs([hogs[0][@"totalImpact"] doubleValue] - 65.7) < 0.001, @"total impact preserves full sample");
        check([hogs[0][@"commands"] containsObject:@"Chrome Helper"], @"Chrome row preserves raw helper command");
        check([hogs[1][@"name"] isEqual:@"WindowServer"], @"WindowServer second (26.7)");
        check([hogs[1][@"commands"] containsObject:@"WindowServer"], @"WindowServer row preserves raw command");
        check([hogs[2][@"name"] isEqual:@"iTerm2"], @"iTerm2 third (4.0)");
        double ws = 0; for (NSDictionary *h in hogs) if ([h[@"name"] isEqual:@"WindowServer"]) ws = [h[@"impact"] doubleValue];
        check(ws == 26.7, @"WindowServer = 26.7 (second frame only)");

        // --- ParseProcessStats grouping ---
        NSString *ps =
            @"101 24.5 200000 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper\n"
             "102  5.5 100000 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper\n"
             "103 12.0  50000 /usr/libexec/syspolicyd\n"
             "104  0.2 400000 /Applications/Adobe Acrobat.app/Contents/MacOS/AdobeAcrobat\n";
        NSDictionary *stats = ParseProcessStats(ps, 3, ^NSString *(pid_t pid) {
            return (pid == 101 || pid == 102) ? @"Google Chrome" : nil;
        }, nil);
        NSArray *cpu = stats[@"cpu"], *mem = stats[@"memory"];
        check([cpu[0][@"name"] isEqual:@"Google Chrome"], @"CPU stats roll Chrome helpers up");
        check(fabs([cpu[0][@"cpu"] doubleValue] - 30.0) < 0.001, @"Chrome CPU is summed");
        check([cpu[0][@"commands"] containsObject:@"Google Chrome Helper"], @"CPU row preserves helper command");
        check([mem[0][@"name"] isEqual:@"AdobeAcrobat"], @"memory stats sort by RSS");
        check([mem[0][@"bytes"] unsignedLongLongValue] == 400000ULL * 1024ULL, @"RSS is converted to bytes");

        // --- ParseProcessStats footprint override ---
        NSDictionary *stats2 = ParseProcessStats(ps, 3,
            ^NSString *(pid_t __unused pid) { return nil; },
            ^unsigned long long (pid_t pid) { return pid == 104 ? 999ULL * 1024 * 1024 : 0; });
        check([stats2[@"memory"][0][@"name"] isEqual:@"AdobeAcrobat"], @"footprint keeps sort order");
        check([stats2[@"memory"][0][@"bytes"] unsignedLongLongValue] == 999ULL * 1024 * 1024,
              @"footprint block overrides RSS when it returns nonzero");
        check([stats2[@"memory"][1][@"bytes"] unsignedLongLongValue] == 300000ULL * 1024ULL,
              @"zero footprint falls back to RSS (grouped helpers summed)");

        // --- ParseTokenCountLine ---
        NSString *tok = @"{\"timestamp\":\"2026-06-10T09:04:20.778Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":104303},\"last_token_usage\":{\"input_tokens\":74038,\"cached_input_tokens\":63360,\"output_tokens\":668,\"total_tokens\":74706},\"model_context_window\":272000},\"rate_limits\":{\"primary\":{\"used_percent\":83.0,\"window_minutes\":300,\"resets_at\":1781093380},\"secondary\":{\"used_percent\":90.0,\"window_minutes\":10080,\"resets_at\":1781179715},\"plan_type\":\"prolite\"}}}";
        NSDictionary *ev = ParseTokenCountLine(tok);
        check(ev != nil, @"token_count line parses");
        check([ev[@"tokens"] longLongValue] == 74706, @"per-turn token delta extracted");
        check([ev[@"fresh"] longLongValue] == 74038 - 63360 + 668, @"fresh excludes cached input");
        check([ev[@"ts"] isEqual:@"2026-06-10T09:04:20.778Z"], @"timestamp extracted");
        check([ev[@"limits"][@"plan_type"] isEqual:@"prolite"], @"rate limits captured");
        check(ParseTokenCountLine(@"{\"timestamp\":\"t\",\"payload\":{\"type\":\"user_message\"}}") == nil,
              @"non-token line skipped");
        check(ParseTokenCountLine(@"not json but mentions token_count") == nil, @"malformed line skipped");
        NSDictionary *startEv = ParseTokenCountLine(@"{\"timestamp\":\"2026-06-10T00:00:01Z\",\"payload\":{\"type\":\"token_count\",\"info\":{},\"rate_limits\":{\"primary\":{\"used_percent\":10.0,\"window_minutes\":300,\"resets_at\":99}}}}");
        check(startEv && [startEv[@"tokens"] longLongValue] == 0, @"session-start event keeps limits, zero tokens");

        // --- ParseClaudeUsageLine ---
        NSString *cl = @"{\"parentUuid\":\"x\",\"isSidechain\":false,\"message\":{\"id\":\"msg_abc\",\"model\":\"claude-fable-5\",\"usage\":{\"input_tokens\":12041,\"cache_creation_input_tokens\":5048,\"cache_read_input_tokens\":16924,\"output_tokens\":643}},\"type\":\"assistant\",\"timestamp\":\"2026-06-09T22:57:36.419Z\"}";
        NSDictionary *cev = ParseClaudeUsageLine(cl);
        check(cev != nil, @"claude usage line parses");
        check([cev[@"fresh"] longLongValue] == 12041 + 643, @"claude fresh = input + output");
        check([cev[@"tokens"] longLongValue] == 12041 + 643 + 5048 + 16924, @"claude total includes cache");
        check([cev[@"id"] isEqual:@"msg_abc"], @"message id surfaced for dedupe");
        check([cev[@"ts"] isEqual:@"2026-06-09T22:57:36.419Z"], @"claude timestamp extracted");
        check(ParseClaudeUsageLine(@"{\"type\":\"user\",\"message\":{\"role\":\"user\"}}") == nil,
              @"non-usage line skipped");
        check(ParseClaudeUsageLine(@"junk with \"usage\" inside") == nil, @"malformed claude line skipped");

        // --- AccumulateTokenEvents ---
        NSTimeZone *tz = [NSTimeZone timeZoneForSecondsFromGMT:10 * 3600];
        NSDictionary *acc = AccumulateTokenEvents(nil, @[
            @{@"ts": @"2026-06-09T20:00:00Z", @"tokens": @100, @"fresh": @10},
            @{@"ts": @"2026-06-09T10:00:00Z", @"tokens": @50, @"fresh": @5},
            @{@"ts": @"2026-06-10T01:00:00.500Z", @"tokens": @7, @"fresh": @2,
              @"limits": @{@"plan_type": @"prolite"}},
        ], tz);
        check([acc[@"days"][@"2026-06-10"][@"t"] longLongValue] == 107, @"UTC events bucket into local day");
        check([acc[@"days"][@"2026-06-10"][@"f"] longLongValue] == 12, @"fresh totals accumulate per day");
        check([acc[@"days"][@"2026-06-09"][@"t"] longLongValue] == 50, @"earlier event stays previous local day");
        check([acc[@"latestLimits"][@"plan_type"] isEqual:@"prolite"], @"latest limits surfaced");
        NSDictionary *acc2 = AccumulateTokenEvents(acc[@"days"],
            @[@{@"ts": @"2026-06-10T02:00:00Z", @"tokens": @3, @"fresh": @1}], tz);
        check([acc2[@"days"][@"2026-06-10"][@"t"] longLongValue] == 110, @"accumulation merges into existing days");
        check([acc2[@"days"][@"2026-06-10"][@"f"] longLongValue] == 13, @"fresh merges too");

        // --- PickLimitWindow ---
        NSDictionary *limits = @{@"primary": @{@"used_percent": @83.0, @"window_minutes": @300, @"resets_at": @2000},
                                 @"secondary": @{@"used_percent": @90.0, @"window_minutes": @10080, @"resets_at": @5000},
                                 @"plan_type": @"prolite"};
        NSDictionary *pick = PickLimitWindow(limits, 1000);
        check(fabs([pick[@"remainingFraction"] doubleValue] - 0.10) < 0.001, @"most constrained window wins");
        check([pick[@"window"] isEqual:@"weekly"], @"weekly window labeled");
        check([pick[@"plan"] isEqual:@"prolite"], @"plan surfaced");
        check(PickLimitWindow(limits, 6000) == nil, @"all-obsolete windows yield nil");
        NSDictionary *pick3 = PickLimitWindow(limits, 3000);
        check([pick3[@"window"] isEqual:@"weekly"], @"reset window excluded, current one kept");
        check(PickLimitWindow(nil, 1000) == nil, @"nil limits yield nil");

        // --- PickClaudeLimitWindow ---
        NSDictionary *cu = @{@"five_hour": @{@"utilization": @37, @"resets_at": @"1970-01-01T00:33:20Z"},
                             @"seven_day": @{@"utilization": @81, @"resets_at": @5000}};
        NSDictionary *cpick = PickClaudeLimitWindow(cu, 1000);
        check(fabs([cpick[@"remainingFraction"] doubleValue] - 0.19) < 0.001, @"claude most constrained window wins");
        check([cpick[@"window"] isEqual:@"weekly"], @"claude weekly labeled");
        NSDictionary *cpickOne = PickClaudeLimitWindow(
            @{@"five_hour": @{@"utilization": @1.0, @"resets_at": @9000}}, 1000);
        check(fabs([cpickOne[@"remainingFraction"] doubleValue] - 0.99) < 0.001,
              @"claude utilization 1.0 means 1 percent used, not a full fraction");
        NSDictionary *cpickFractionalPercent = PickClaudeLimitWindow(
            @{@"five_hour": @{@"utilization": @0.4, @"resets_at": @9000}}, 1000);
        check(fabs([cpickFractionalPercent[@"remainingFraction"] doubleValue] - 0.996) < 0.001,
              @"claude sub-1 utilization remains a fractional percentage");
        NSDictionary *cpickFull = PickClaudeLimitWindow(
            @{@"five_hour": @{@"utilization": @100.0, @"resets_at": @9000}}, 1000);
        check(fabs([cpickFull[@"remainingFraction"] doubleValue]) < 0.001,
              @"claude utilization 100 means no quota remaining");
        check(PickClaudeLimitWindow(@{@"five_hour": @{@"utilization": @37, @"resets_at": @500}}, 1000) == nil,
              @"claude obsolete window skipped");
        check(PickClaudeLimitWindow(@{@"five_hour": @{@"utilization": @37, @"resets_at": @1000}}, 1000) == nil,
              @"claude window resetting exactly now is elapsed");
        check(PickClaudeLimitWindow(@{@"five_hour": @{@"utilization": @100}}, 1000) == nil,
              @"claude reset-less placeholder cannot drive headline");
        NSDictionary *placeholderPick = PickClaudeLimitWindow(
            @{@"five_hour": @{@"utilization": @20, @"resets_at": @9000},
              @"seven_day_opus": @{@"utilization": @100}}, 1000);
        check([placeholderPick[@"window"] isEqual:@"5-hour"] &&
              fabs([placeholderPick[@"remainingFraction"] doubleValue] - 0.80) < 0.001,
              @"claude reset-less weekly Opus placeholder cannot override live headline");
        check(PickClaudeLimitWindow(@{@"future_window": @{@"utilization": @99, @"resets_at": @9000}}, 1000) == nil,
              @"claude unknown window cannot drive headline");
        NSDictionary *knownPick = PickClaudeLimitWindow(
            @{@"future_window": @{@"utilization": @99, @"resets_at": @9000},
              @"five_hour": @{@"utilization": @20, @"resets_at": @9000}}, 1000);
        check([knownPick[@"window"] isEqual:@"5-hour"] &&
              fabs([knownPick[@"remainingFraction"] doubleValue] - 0.80) < 0.001,
              @"claude known current window wins over unknown bucket");
        check(PickClaudeLimitWindow(@{@"error": @{@"type": @"rate_limit_error"}}, 1000) == nil,
              @"error response yields nil");
        // Real response shape: percent utilization, microsecond ISO resets, null windows,
        // and an extra_usage credit budget that must not win the picker.
        NSDictionary *real = @{@"five_hour": @{@"utilization": @76.0, @"resets_at": @"2026-06-10T13:40:00.730662+00:00"},
                               @"seven_day": @{@"utilization": @55.0, @"resets_at": @"2026-06-16T13:00:00.730687+00:00"},
                               @"seven_day_opus": NSNull.null,
                               @"extra_usage": @{@"utilization": @91.22, @"monthly_limit": @10000}};
        NSDictionary *rpick = PickClaudeLimitWindow(real, 1781000000.0);   // 2026-06-09
        check(fabs([rpick[@"remainingFraction"] doubleValue] - 0.24) < 0.001,
              @"extra_usage excluded; 5-hour window wins");
        check([rpick[@"window"] isEqual:@"5-hour"], @"5-hour window labeled");
        // weekly Sonnet must never drive the bar, even when it is the most-constrained window.
        NSDictionary *spick = PickClaudeLimitWindow(@{@"five_hour": @{@"utilization": @20.0, @"resets_at": @9000},
                                                      @"seven_day_sonnet": @{@"utilization": @99.0, @"resets_at": @9000}}, 1000);
        check([spick[@"window"] isEqual:@"5-hour"], @"weekly Sonnet never picked even when most constrained");
        check([rpick[@"resetsAt"] doubleValue] > 1781000000.0, @"microsecond ISO reset parsed");
        NSDictionary *extra = ClaudeExtraUsageStatus(real);
        check(extra && [extra[@"statusReason"] isEqual:@"Extra usage active"], @"extra_usage below limit is account status");
        check(![extra[@"overageActive"] boolValue], @"extra_usage below limit is not overage");
        NSDictionary *overage = ClaudeExtraUsageStatus(@{@"extra_usage": @{@"is_enabled": @YES,
                                                                           @"used_credits": @10500,
                                                                           @"monthly_limit": @10000,
                                                                           @"currency": @"AUD",
                                                                           @"utilization": @105.0}});
        check([overage[@"overageActive"] boolValue], @"extra_usage over limit is overage");
        check([overage[@"statusReason"] isEqual:@"Overage billing active"], @"overage status is explicit");
        check(!ShouldFetchClaudeAccount(YES, NO, NO, NO, 1000, 2000),
              @"hidden Claude account UI does not fetch");
        check(ShouldFetchClaudeAccount(YES, YES, NO, NO, 1000, 2000),
              @"visible Claude account with no cached status fetches despite future retry");
        check(!ShouldFetchClaudeAccount(YES, YES, NO, YES, 1000, 2000),
              @"visible Claude account keeps cached error until retry");
        check(ShouldFetchClaudeAccount(YES, YES, YES, YES, 2500, 2000),
              @"visible Claude account fetches after retry interval");

        // --- ClaudeLimitWindows (all current windows for the dual meter) ---
        NSDictionary *cwAll = @{@"five_hour": @{@"utilization": @76.0, @"resets_at": @4000},
                                @"seven_day": @{@"utilization": @55.0, @"resets_at": @9000},
                                @"seven_day_opus": NSNull.null,
                                @"extra_usage": @{@"utilization": @91.0, @"monthly_limit": @10000}};
        NSArray *cwins = ClaudeLimitWindows(cwAll, 1000);
        check(cwins.count == 2, @"claude returns both current windows (extra_usage excluded)");
        check([cwins[0][@"window"] isEqual:@"5-hour"], @"claude 5-hour ordered first");
        check([cwins[1][@"window"] isEqual:@"weekly"], @"claude weekly ordered second");
        check(fabs([cwins[0][@"remainingFraction"] doubleValue] - 0.24) < 0.001, @"claude 5-hour remaining = 1-0.76");
        check(fabs([cwins[1][@"remainingFraction"] doubleValue] - 0.45) < 0.001, @"claude weekly remaining = 1-0.55");
        check([cwins[0][@"resetsAt"] doubleValue] == 4000, @"claude 5-hour reset surfaced");
        NSArray *cwinsPercent = ClaudeLimitWindows(
            @{@"five_hour": @{@"utilization": @1.0, @"resets_at": @4000},
              @"seven_day": @{@"utilization": @100.0, @"resets_at": @9000}}, 1000);
        check(fabs([cwinsPercent[0][@"remainingFraction"] doubleValue] - 0.99) < 0.001,
              @"claude dual meter treats 1.0 as 1 percent used");
        check(fabs([cwinsPercent[1][@"remainingFraction"] doubleValue]) < 0.001,
              @"claude dual meter treats 100 as fully used");
        NSArray *cwins2 = ClaudeLimitWindows(@{@"five_hour": @{@"utilization": @20.0, @"resets_at": @500},
                                               @"seven_day": @{@"utilization": @55.0, @"resets_at": @9000}}, 1000);
        check(cwins2.count == 1 && [cwins2[0][@"window"] isEqual:@"weekly"], @"claude drops reset-elapsed window");
        check(ClaudeLimitWindows(nil, 1000).count == 0, @"claude nil usage ⇒ empty");
        check(ClaudeLimitWindows(@{@"error": @{@"type": @"rate_limit_error"}}, 1000).count == 0, @"claude error ⇒ empty");
        NSArray *cwins3 = ClaudeLimitWindows(@{@"seven_day": @{@"utilization": @10.0, @"resets_at": @9000},
                                               @"five_hour": @{@"utilization": @10.0, @"resets_at": @9000}}, 1000);
        check([cwins3[0][@"window"] isEqual:@"5-hour"], @"claude order is fixed (5-hour first) regardless of dict order");
        // weekly Sonnet is never surfaced, even with a real future reset and live utilization.
        NSArray *cwins5 = ClaudeLimitWindows(@{@"five_hour": @{@"utilization": @76.0, @"resets_at": @4000},
                                               @"seven_day": @{@"utilization": @55.0, @"resets_at": @9000},
                                               @"seven_day_sonnet": @{@"utilization": @30.0, @"resets_at": @9000}}, 1000);
        check(cwins5.count == 2, @"claude never surfaces weekly Sonnet");
        check([cwins5[1][@"window"] isEqual:@"weekly"], @"weekly Sonnet dropped; overall weekly kept");
        // A reset-less placeholder window (e.g. an unused weekly Opus) is still excluded.
        NSArray *cwins6 = ClaudeLimitWindows(@{@"five_hour": @{@"utilization": @76.0, @"resets_at": @4000},
                                               @"seven_day": @{@"utilization": @55.0, @"resets_at": @9000},
                                               @"seven_day_opus": @{@"utilization": @0.0}}, 1000);
        check(cwins6.count == 2, @"claude excludes a reset-less placeholder window (e.g. unused weekly Opus)");
        NSArray *cwins7 = ClaudeLimitWindows(@{@"five_hour": @{@"utilization": @76.0},
                                               @"seven_day": @{@"utilization": @55.0, @"resets_at": @9000},
                                               @"future_window": @{@"utilization": @99.0, @"resets_at": @9000}}, 1000);
        check(cwins7.count == 1 && [cwins7[0][@"window"] isEqual:@"weekly"],
              @"claude dual meter drops reset-less known and current unknown windows");
        NSArray *cwins8 = ClaudeLimitWindows(@{@"five_hour": @{@"utilization": @76.0, @"resets_at": @1000},
                                               @"seven_day": @{@"utilization": @55.0, @"resets_at": @1001}}, 1000);
        check(cwins8.count == 1 && [cwins8[0][@"window"] isEqual:@"weekly"],
              @"claude dual meter drops a window whose reset is exactly elapsed");

        // --- CodexLimitWindows (all current windows for the dual meter) ---
        NSDictionary *xlimits = @{@"primary": @{@"used_percent": @83.0, @"window_minutes": @300, @"resets_at": @4000},
                                  @"secondary": @{@"used_percent": @90.0, @"window_minutes": @10080, @"resets_at": @9000},
                                  @"plan_type": @"prolite"};
        NSArray *xwins = CodexLimitWindows(xlimits, 1000);
        check(xwins.count == 2, @"codex returns both current windows");
        check([xwins[0][@"window"] isEqual:@"5-hour"], @"codex 5-hour (primary) first");
        check([xwins[1][@"window"] isEqual:@"weekly"], @"codex weekly (secondary) second");
        check(fabs([xwins[0][@"remainingFraction"] doubleValue] - 0.17) < 0.001, @"codex 5-hour remaining = 1-0.83");
        check(fabs([xwins[1][@"remainingFraction"] doubleValue] - 0.10) < 0.001, @"codex weekly remaining = 1-0.90");
        check([xwins[1][@"plan"] isEqual:@"prolite"], @"codex plan surfaced on windows");
        NSArray *xwins2 = CodexLimitWindows(@{@"primary": @{@"used_percent": @83.0, @"window_minutes": @300, @"resets_at": @500},
                                              @"secondary": @{@"used_percent": @90.0, @"window_minutes": @10080, @"resets_at": @9000}}, 1000);
        check(xwins2.count == 1 && [xwins2[0][@"window"] isEqual:@"weekly"], @"codex drops reset-elapsed window");
        check(CodexLimitWindows(nil, 1000).count == 0, @"codex nil ⇒ empty");

        // --- RateLimitRetryDelay ---
        check(RateLimitRetryDelay(0) == 900, @"no Retry-After ⇒ 900s floor");
        check(RateLimitRetryDelay(600) == 900, @"short Retry-After ⇒ 900s floor");
        check(RateLimitRetryDelay(2000) == 2000, @"reasonable Retry-After honored");
        check(RateLimitRetryDelay(86400) == 3600, @"huge Retry-After capped at 3600s");

        // --- ShouldDropCachedTokenForStatus ---
        check(ShouldDropCachedTokenForStatus(401), @"401 drops the cached token");
        check(ShouldDropCachedTokenForStatus(403), @"403 drops the cached token");
        check(!ShouldDropCachedTokenForStatus(429), @"429 keeps the cached token");
        check(!ShouldDropCachedTokenForStatus(500), @"500 keeps the cached token");
        check(!ShouldDropCachedTokenForStatus(0), @"transport error keeps the cached token");

        // --- ClaudeKeychainOutcome ---
        NSDictionary *kcMissing = ClaudeKeychainOutcome(NO, nil, 0, 1000);
        check(![kcMissing[@"ok"] boolValue], @"missing keychain item ⇒ not ok");
        check([kcMissing[@"retryDelay"] doubleValue] == 3600, @"missing item backs off 1h (avoid prompt spam)");
        check([kcMissing[@"status"] isEqual:@"Keychain token unavailable; retrying later"],
              @"missing item keeps the existing message");
        NSDictionary *kcEmpty = ClaudeKeychainOutcome(YES, @"", 2000, 1000);
        check(![kcEmpty[@"ok"] boolValue] && [kcEmpty[@"retryDelay"] doubleValue] == 3600,
              @"empty token is treated as missing");
        NSDictionary *kcExpired = ClaudeKeychainOutcome(YES, @"tok", 999, 1000);
        check(![kcExpired[@"ok"] boolValue], @"expired token ⇒ not ok");
        check([kcExpired[@"retryDelay"] doubleValue] == 300, @"expired token retries in 5 min, not 1h");
        check([kcExpired[@"status"] isEqual:@"Claude Code token expired; waiting for it to refresh"],
              @"expired token names the real condition");
        NSDictionary *kcOk = ClaudeKeychainOutcome(YES, @"tok", 5000, 1000);
        check([kcOk[@"ok"] boolValue] && [kcOk[@"token"] isEqual:@"tok"], @"future expiry ⇒ usable token");
        NSDictionary *kcNoExpiry = ClaudeKeychainOutcome(YES, @"tok", 0, 1000);
        check([kcNoExpiry[@"ok"] boolValue], @"unknown expiry (0) is trusted");

        // --- CodexLimitStatusReason ---
        check([CodexLimitStatusReason(nil, nil, 1000)
                  isEqual:@"Codex session logs do not carry limit status"],
              @"no rate_limits ever seen ⇒ do-not-carry");
        check([CodexLimitStatusReason(@{@"primary": @{@"window_minutes": @300}}, nil, 1000)
                  isEqual:@"Codex session logs do not carry limit status"],
              @"windows without used_percent are malformed ⇒ do-not-carry");
        check(CodexLimitStatusReason(@{@"primary": @{@"used_percent": @83.0, @"resets_at": @2000}},
                                     @"2026-06-10T09:25:32Z", 1000) == nil,
              @"unexpired window ⇒ nil (gauge shows)");
        check(CodexLimitStatusReason(@{@"primary": @{@"used_percent": @83.0, @"resets_at": @500},
                                       @"secondary": @{@"used_percent": @91.0, @"resets_at": @2000}},
                                     @"2026-06-10T09:25:32Z", 1000) == nil,
              @"one expired but the other current ⇒ nil (gauge shows)");
        NSString *expiredReason = CodexLimitStatusReason(
            @{@"primary": @{@"used_percent": @83.0, @"resets_at": @500},
              @"secondary": @{@"used_percent": @91.0, @"resets_at": @900}},
            @"2026-06-10T09:25:32Z", 1000);
        check([expiredReason hasPrefix:@"Limit windows reset since last Codex session ("],
              @"all windows expired ⇒ dated stale message");
        check([CodexLimitStatusReason(@{@"primary": @{@"used_percent": @83.0, @"resets_at": @500}},
                                      nil, 1000)
                  isEqual:@"Limit windows reset since last Codex session"],
              @"expired with no snapshot timestamp ⇒ undated stale message");

        // --- PickCursorLimitWindow / CursorLimitWindows ---
        // Pro/Team shape from GetCurrentPeriodUsage: included spend in cents.
        NSDictionary *cursorPlan = @{
            @"billingCycleStart": @"1768399334000",
            @"billingCycleEnd": @"1771077734000",
            @"planUsage": @{
                @"totalSpend": @23222,
                @"includedSpend": @23222,
                @"remaining": @16778,
                @"limit": @40000,
                @"totalPercentUsed": @58.055,
                @"apiPercentUsed": @46.444,
                @"autoPercentUsed": @0
            }
        };
        NSDictionary *cursorPick = PickCursorLimitWindow(cursorPlan, 1770000000.0);
        check(fabs([cursorPick[@"remainingFraction"] doubleValue] - (16778.0 / 40000.0)) < 0.001,
              @"cursor remaining/limit drives the gauge");
        check([cursorPick[@"window"] isEqual:@"billing period"], @"cursor billing window labeled");
        check(fabs([cursorPick[@"resetsAt"] doubleValue] - 1771077734.0) < 0.001,
              @"cursor billingCycleEnd ms → epoch seconds");
        check(PickCursorLimitWindow(cursorPlan, 1771077734.0) == nil,
              @"cursor cycle that has already ended yields nil");
        // Prefer remaining/limit over totalPercentUsed when both are present.
        NSDictionary *cursorPctOnly = PickCursorLimitWindow(
            @{@"billingCycleEnd": @1771077734000,
              @"planUsage": @{@"totalPercentUsed": @25.0, @"limit": @10000}}, 1770000000.0);
        check(fabs([cursorPctOnly[@"remainingFraction"] doubleValue] - 0.75) < 0.001,
              @"cursor falls back to 1 - totalPercentUsed/100 when remaining absent");
        NSDictionary *cursorSpendOnly = PickCursorLimitWindow(
            @{@"billingCycleEnd": @"1771077734000",
              @"planUsage": @{@"includedSpend": @2500, @"limit": @10000}}, 1770000000.0);
        check(fabs([cursorSpendOnly[@"remainingFraction"] doubleValue] - 0.75) < 0.001,
              @"cursor falls back to 1 - includedSpend/limit");
        check(PickCursorLimitWindow(@{@"planUsage": @{@"limit": @0, @"remaining": @0}}, 1000) == nil,
              @"cursor zero limit is not a usable gauge");
        check(PickCursorLimitWindow(nil, 1000) == nil, @"cursor nil usage yields nil");
        // Enterprise/legacy /auth/usage: request buckets.
        NSDictionary *cursorAuth = @{
            @"gpt-4": @{@"numRequests": @150, @"maxRequestUsage": @500},
            @"gpt-3.5-turbo": @{@"numRequests": @10, @"maxRequestUsage": @0},
            @"startOfMonth": @"2026-03-01T00:00:00.000Z"
        };
        NSDictionary *authPick = PickCursorLimitWindow(cursorAuth, 1770000000.0);
        check(fabs([authPick[@"remainingFraction"] doubleValue] - 0.70) < 0.001,
              @"cursor auth/usage remaining = 1 - num/max");
        check([authPick[@"window"] isEqual:@"gpt-4"], @"cursor auth bucket labeled by model key");
        NSArray *cursorWins = CursorLimitWindows(cursorPlan, 1770000000.0);
        check(cursorWins.count == 1 && [cursorWins[0][@"window"] isEqual:@"billing period"],
              @"cursor planUsage surfaces one billing window");
        NSArray *authWins = CursorLimitWindows(cursorAuth, 1770000000.0);
        check(authWins.count == 1 && [authWins[0][@"window"] isEqual:@"gpt-4"],
              @"cursor auth/usage skips buckets with maxRequestUsage 0");
        // planUsage wins when both shapes are somehow present.
        NSMutableDictionary *mixed = [cursorPlan mutableCopy];
        mixed[@"gpt-4"] = @{@"numRequests": @499, @"maxRequestUsage": @500};
        NSDictionary *mixedPick = PickCursorLimitWindow(mixed, 1770000000.0);
        check([mixedPick[@"window"] isEqual:@"billing period"],
              @"cursor planUsage overrides legacy auth buckets");

        // --- ParseSleepDisabled (`pmset -g` → lid-closed-awake state) ---
        check([ParseSleepDisabled(@" SleepDisabled\t\t0") isEqual:@NO], @"SleepDisabled 0 → NO");
        check([ParseSleepDisabled(@" SleepDisabled 1") isEqual:@YES], @"SleepDisabled 1 → YES");
        check(ParseSleepDisabled(@"") == nil, @"empty input → nil (unknown)");
        check(ParseSleepDisabled(@"System-wide power settings:\n standby 1\n") == nil,
              @"line absent → nil (unknown)");
        NSString *pmsetOn =
            @"System-wide power settings:\n SleepDisabled          1\n"
             "Currently in use:\n standby              1\n hibernatemode        3\n";
        check([ParseSleepDisabled(pmsetOn) isEqual:@YES], @"picks SleepDisabled=1 from a full pmset -g block");
        NSString *pmsetOff =
            @"System-wide power settings:\n SleepDisabled\t\t0\nCurrently in use:\n standby 1\n";
        check([ParseSleepDisabled(pmsetOff) isEqual:@NO], @"picks SleepDisabled=0 from a full pmset -g block");
        check(ParseSleepDisabled(@" SleepDisabledExtra 1") == nil,
              @"does not match a longer token (SleepDisabledExtra)");
        check([ParseSleepDisabled(@" SleepDisabled 2") isEqual:@YES], @"any nonzero value → YES");

        fprintf(stderr, "\n%s (%d failure%s)\n", failures ? "TESTS FAILED" : "ALL TESTS PASSED",
                failures, failures == 1 ? "" : "s");
        return failures ? 1 : 0;
    }
}
