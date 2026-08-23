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
        NSDictionary *nullUsage = ParseClaudeUsageLine(@"{\"timestamp\":\"2026-06-10T00:00:01Z\",\"message\":{\"usage\":{\"input_tokens\":5,\"output_tokens\":null,\"cache_read_input_tokens\":null}}}");
        check(nullUsage && [nullUsage[@"tokens"] longLongValue] == 5, @"null token counters read as zero");
        NSDictionary *nullTok = ParseTokenCountLine(@"{\"timestamp\":\"2026-06-10T00:00:01Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":9,\"input_tokens\":null,\"cached_input_tokens\":null,\"output_tokens\":null}}}}");
        check(nullTok && [nullTok[@"fresh"] longLongValue] == 0, @"null codex token counters read as zero");

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
        // JSON null in any scalar must read as zero, never abort the process.
        NSDictionary *nullLimits = @{@"primary": @{@"used_percent": @83.0,
                                                   @"window_minutes": NSNull.null,
                                                   @"resets_at": NSNull.null}};
        NSDictionary *npick = PickLimitWindow(nullLimits, 1000);
        check(npick != nil, @"null resets_at/window_minutes still yields a window");
        check([npick[@"window"] isEqual:@"usage"], @"null window_minutes falls back to generic label");
        check(npick[@"resetsAt"] == nil, @"null resets_at surfaces no reset time");
        check(CodexLimitWindows(nullLimits, 1000).count == 1, @"codex tolerates null scalars");
        check(CodexLimitStatusReason(nullLimits, @"", 1000) == nil, @"status reason tolerates null resets_at");

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
        // The live API sends JSON null for these before any extra usage is consumed;
        // NSNull does not respond to doubleValue, so unguarded reads abort the app.
        NSDictionary *nulls = ClaudeExtraUsageStatus(@{@"extra_usage": @{@"is_enabled": @YES,
                                                                         @"used_credits": NSNull.null,
                                                                         @"monthly_limit": @10000,
                                                                         @"currency": @"USD",
                                                                         @"utilization": NSNull.null}});
        check(nulls != nil, @"null utilization/used_credits still yields a status");
        check(![nulls[@"overageActive"] boolValue], @"null usage counters are not overage");
        check([nulls[@"description"] isEqual:@"0 of 10000 USD (0%)"], @"null usage counters read as zero");
        NSDictionary *missing = ClaudeExtraUsageStatus(@{@"extra_usage": @{@"is_enabled": @YES,
                                                                           @"monthly_limit": @10000}});
        check(missing && ![missing[@"overageActive"] boolValue], @"absent usage counters are not overage");
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

        // --- ClaudeStaleLimitWindows / PickClaudeStaleLimitWindow / ClaudeLimitStatusReason ---
        NSDictionary *elapsed = @{@"five_hour": @{@"utilization": @40.0, @"resets_at": @500},
                                  @"seven_day": @{@"utilization": @80.0, @"resets_at": @900}};
        check(ClaudeLimitWindows(elapsed, 1000).count == 0, @"live claude empty when all elapsed");
        NSArray *staleWins = ClaudeStaleLimitWindows(elapsed, 1000);
        check(staleWins.count == 2, @"stale claude keeps elapsed known windows");
        check([staleWins[0][@"window"] isEqual:@"5-hour"], @"stale claude keeps live order");
        check([staleWins[1][@"window"] isEqual:@"weekly"], @"stale claude weekly second");
        NSDictionary *stalePick = PickClaudeStaleLimitWindow(elapsed, 1000);
        check([stalePick[@"window"] isEqual:@"weekly"], @"stale pick prefers most recently expired");
        check(fabs([stalePick[@"remainingFraction"] doubleValue] - 0.20) < 0.001,
              @"stale pick keeps utilization");
        check([stalePick[@"resetsAt"] doubleValue] == 900, @"stale pick keeps last-known reset");
        check(PickClaudeStaleLimitWindow(@{@"seven_day_opus": @{@"utilization": @100}}, 1000) == nil,
              @"reset-less placeholder cannot be stale pick");
        check(PickClaudeStaleLimitWindow(
                  @{@"five_hour": @{@"utilization": @10, @"resets_at": @9000}}, 1000) == nil,
              @"still-current window is not a stale pick");
        check(ClaudeStaleLimitWindows(
                  @{@"five_hour": @{@"utilization": @10, @"resets_at": @9000},
                    @"seven_day_opus": @{@"utilization": @100}}, 1000).count == 0,
              @"stale list excludes live windows and reset-less placeholders");
        NSString *claudeElapsedReason = ClaudeLimitStatusReason(elapsed, @"2026-08-10T01:41:00Z", 1000);
        check([claudeElapsedReason hasPrefix:@"Limit windows reset since last Claude refresh ("],
              @"claude elapsed status is dated");
        check(ClaudeLimitStatusReason(
                  @{@"five_hour": @{@"utilization": @10, @"resets_at": @9000}},
                  @"2026-08-10T01:41:00Z", 1000) == nil,
              @"claude status nil while a live window exists");
        check([ClaudeLimitStatusReason(@{}, @"", 1000)
                  isEqual:@"Account response has no current limit window"],
              @"claude empty usage yields the missing-window reason");
        check([ClaudeLimitStatusReason(elapsed, nil, 1000)
                  isEqual:@"Limit windows reset since last Claude refresh"],
              @"claude elapsed with no fetch timestamp is undated");

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
        // Was "do-not-carry": a window object with no used_percent is malformed, and
        // saying which way it is malformed beats blaming the logs for carrying nothing.
        check([CodexLimitStatusReason(@{@"primary": @{@"window_minutes": @300}}, nil, 1000)
                  isEqual:@"Limit windows changed shape (no used_percent)"],
              @"windows without used_percent report the shape change, not silence");
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

        // --- CursorStaleLimitWindows / PickCursorStaleLimitWindow / CursorLimitStatusReason ---
        NSDictionary *cursorElapsed = @{
            @"billingCycleEnd": @1771077734000,
            @"planUsage": @{@"remaining": @16778, @"limit": @40000}
        };
        check(CursorLimitWindows(cursorElapsed, 1771077734.0).count == 0,
              @"live cursor empty when billing cycle ended");
        NSArray *cursorStaleWins = CursorStaleLimitWindows(cursorElapsed, 1771077734.0);
        check(cursorStaleWins.count == 1, @"stale cursor keeps elapsed billing window");
        NSDictionary *cursorStalePick = PickCursorStaleLimitWindow(cursorElapsed, 1771077734.0);
        check([cursorStalePick[@"window"] isEqual:@"billing period"], @"stale cursor billing labeled");
        check(fabs([cursorStalePick[@"remainingFraction"] doubleValue] - (16778.0 / 40000.0)) < 0.001,
              @"stale cursor keeps remaining fraction");
        check(fabs([cursorStalePick[@"resetsAt"] doubleValue] - 1771077734.0) < 0.001,
              @"stale cursor keeps last-known cycle end");
        check(PickCursorStaleLimitWindow(cursorPlan, 1770000000.0) == nil,
              @"still-current cursor cycle is not a stale pick");
        NSString *cursorElapsedReason = CursorLimitStatusReason(cursorElapsed, @"2026-08-10T01:41:00Z",
                                                                1771077734.0);
        check([cursorElapsedReason hasPrefix:@"Limit windows reset since last Cursor refresh ("],
              @"cursor elapsed status is dated");
        check(CursorLimitStatusReason(cursorPlan, @"2026-08-10T01:41:00Z", 1770000000.0) == nil,
              @"cursor status nil while a live window exists");
        check([CursorLimitStatusReason(@{}, @"", 1000)
                  isEqual:@"Account response has no current limit window"],
              @"cursor empty usage yields the missing-window reason");
        check([CursorLimitStatusReason(cursorElapsed, nil, 1771077734.0)
                  isEqual:@"Limit windows reset since last Cursor refresh"],
              @"cursor elapsed with no fetch timestamp is undated");

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

        // --- ChooseBarTier ---
        {
            const double W[3] = {121, 55, 22};   // full, icons, glyph (points)
            const double T = 10000;              // arbitrary epoch base for the clock
            double t = T;
            BarTierState s = {BarTierFull, 0, 0};
            // Plenty of room: stays full, no streak.
            s = ChooseBarTier(s, 200, W, NO, t);
            check(s.tier == BarTierFull && s.expandStreak == 0, @"tier: roomy gap holds full");
            // Gap collapses to 31 pt (the 2026-08-12 incident): straight to glyph.
            s = ChooseBarTier(s, 31, W, NO, t += 15);
            check(s.tier == BarTierGlyph, @"tier: 31pt gap shrinks past icons to glyph");
            // Gap that fits icons exactly with shrink margin picks icons, not glyph.
            s = (BarTierState){BarTierFull, 0, 0};
            s = ChooseBarTier(s, 60, W, NO, t += 15);
            check(s.tier == BarTierIcons, @"tier: 60pt gap fits icons (55+4<=60)");
            // Nothing fits: glyph is the floor — never voluntarily hidden.
            s = (BarTierState){BarTierGlyph, 0, 0};
            s = ChooseBarTier(s, 10, W, NO, t += 15);
            check(s.tier == BarTierGlyph, @"tier: glyph floor even when glyph overflows");
            // Expansion needs slack: icons fit without the 24pt margin ⇒ no expand ever.
            s = (BarTierState){BarTierGlyph, 0, 0};
            for (int i = 0; i < 3; i++) s = ChooseBarTier(s, 70, W, NO, t += 15);
            check(s.tier == BarTierGlyph && s.expandStreak == 0, @"tier: fit-without-slack never expands (anti-flap)");
            // With slack (55+24<=85): expands after exactly kBarExpandTicks counted decisions.
            s = (BarTierState){BarTierGlyph, 0, 0};
            s = ChooseBarTier(s, 85, W, NO, t += 15);
            check(s.tier == BarTierGlyph && s.expandStreak == 1, @"tier: first slack tick only counts");
            s = ChooseBarTier(s, 85, W, NO, t += 15);
            check(s.tier == BarTierIcons && s.expandStreak == 0, @"tier: second slack tick expands one tier");
            // THE BURST GUARD: updateBar fires many times per second during IOPS bursts.
            // Qualifying decisions closer together than kBarExpandMinIntervalSec must not
            // count, or a 30-second promise collapses into milliseconds (observed live).
            s = (BarTierState){BarTierGlyph, 0, 0};
            s = ChooseBarTier(s, 85, W, NO, t += 15);
            check(s.expandStreak == 1, @"tier: burst — first decision counts");
            for (int i = 0; i < 20; i++) s = ChooseBarTier(s, 85, W, NO, t += 0.01);
            check(s.tier == BarTierGlyph && s.expandStreak == 1,
                  @"tier: burst of 20 qualifying decisions in 0.2s cannot expand");
            s = ChooseBarTier(s, 85, W, NO, t += kBarExpandMinIntervalSec);
            check(s.tier == BarTierIcons, @"tier: expands once the wall clock actually advances");
            // An interruption resets the streak.
            s = (BarTierState){BarTierGlyph, 0, 0};
            s = ChooseBarTier(s, 85, W, NO, t += 15);
            s = ChooseBarTier(s, -1, W, NO, t += 15);
            check(s.tier == BarTierGlyph && s.expandStreak == 0, @"tier: unknown gap holds tier, resets streak");
            s = ChooseBarTier(s, 85, W, NO, t += 15);
            check(s.tier == BarTierGlyph && s.expandStreak == 1, @"tier: streak restarts after reset");
            // Eviction overrides a (stale) roomy measurement.
            s = (BarTierState){BarTierFull, 1, 0};
            s = ChooseBarTier(s, 500, W, YES, t += 15);
            check(s.tier == BarTierGlyph && s.expandStreak == 0, @"tier: eviction forces glyph despite roomy gap");
            // Full recovery from glyph is one tier per step: glyph→icons→full.
            s = (BarTierState){BarTierGlyph, 0, 0};
            for (int i = 0; i < 2; i++) s = ChooseBarTier(s, 500, W, NO, t += 15);
            check(s.tier == BarTierIcons, @"tier: recovery step 1 lands icons");
            for (int i = 0; i < 2; i++) s = ChooseBarTier(s, 500, W, NO, t += 15);
            check(s.tier == BarTierFull, @"tier: recovery step 2 lands full");
            // A degenerate width vector (a tier that measures wider than the one below it)
            // must still terminate at a real tier, never spin or overrun the array.
            const double DEGEN[3] = {18, 4, 22};
            s = (BarTierState){BarTierFull, 0, 0};
            s = ChooseBarTier(s, 12, DEGEN, NO, t += 15);
            check(s.tier >= BarTierFull && s.tier <= BarTierGlyph, @"tier: degenerate widths stay in range");
        }

        // --- MergeCodexRateLimits / CodexCreditsStatus ---
        // Shapes taken from real ~/.codex rollouts across the 2026-08-22 transition,
        // where a spent weekly allowance under limit_id "codex" was followed by
        // null-window snapshots under limit_id "premium".
        {
            NSString *windowedTs = @"2026-08-22T02:24:10.143Z";
            NSString *nullTs = @"2026-08-23T04:26:27.057Z";
            NSDictionary *credits = @{@"has_credits": @NO, @"unlimited": @NO, @"balance": @"0"};
            NSDictionary *windowed = @{@"limit_id": @"codex",
                                       @"primary": @{@"used_percent": @100.0, @"window_minutes": @10080,
                                                     @"resets_at": @1787802739},
                                       @"secondary": NSNull.null,
                                       @"credits": credits};
            NSDictionary *blank = @{@"limit_id": @"premium",
                                    @"primary": NSNull.null, @"secondary": NSNull.null,
                                    @"credits": credits};
            double before = 1787479938;   // 2026-08-23, four days short of the reset

            NSDictionary *merged = MergeCodexRateLimits(windowed, windowedTs, blank, nullTs);
            check([merged[@"limit_id"] isEqual:@"premium"], @"codex merge: newest snapshot supplies the scalars");
            NSDictionary *pick = PickLimitWindow(merged, before);
            check(pick && [pick[@"window"] isEqual:@"weekly"],
                  @"codex merge: a null-window snapshot cannot erase the known window");
            check([pick[@"remainingFraction"] doubleValue] == 0, @"codex merge: spent window still reads 0%");
            check([pick[@"resetsAt"] doubleValue] == 1787802739, @"codex merge: the reset survives");
            check([pick[@"observedAt"] isEqual:windowedTs],
                  @"codex merge: a carried-forward window reports its own observation, not the snapshot's");
            // Order independence: the log is not guaranteed to arrive newest-last.
            NSDictionary *reversed = MergeCodexRateLimits(blank, nullTs, windowed, windowedTs);
            NSDictionary *reversedPick = PickLimitWindow(reversed, before);
            check(reversedPick && [reversedPick[@"resetsAt"] doubleValue] == 1787802739,
                  @"codex merge: folding in either order keeps the window");
            check([reversed[@"limit_id"] isEqual:@"premium"],
                  @"codex merge: folding in either order keeps the newest scalars");
            // A newer real reading replaces an older one rather than being retained.
            NSDictionary *fresher = @{@"limit_id": @"codex",
                                      @"primary": @{@"used_percent": @12.0, @"window_minutes": @10080,
                                                    @"resets_at": @1788407539}};
            NSDictionary *advanced = MergeCodexRateLimits(merged, nullTs, fresher, @"2026-08-27T14:00:00.000Z");
            check([[PickLimitWindow(advanced, before) valueForKey:@"resetsAt"] doubleValue] == 1788407539,
                  @"codex merge: a newer window reading wins outright");
            // The regression that made this a pair: primary and secondary describe one
            // bucket, so a secondary from a bucket billed days ago must not pair with a
            // primary from today — that renders as 0% left beside 100% left.
            NSDictionary *otherBucket = @{@"limit_id": @"codex_bengalfox",
                                          @"secondary": @{@"used_percent": @0.0, @"window_minutes": @10080,
                                                          @"resets_at": @1787848682}};
            NSDictionary *mixed = MergeCodexRateLimits(otherBucket, @"2026-08-20T16:38:33.384Z",
                                                       windowed, windowedTs);
            check(CodexLimitWindows(mixed, before).count == 1,
                  @"codex merge: windows move as a pair, never mixed across buckets");
            NSDictionary *stillMixed = MergeCodexRateLimits(mixed, windowedTs, blank, nullTs);
            check(CodexLimitWindows(stillMixed, before).count == 1,
                  @"codex merge: the discarded bucket does not return on the next fold");

            check(CodexCreditsStatus(nil) == nil, @"codex credits: absent ⇒ nil");
            check(CodexCreditsStatus(@{@"primary": NSNull.null}) == nil, @"codex credits: no credits object ⇒ nil");
            NSDictionary *empty = CodexCreditsStatus(merged);
            check([empty[@"exhausted"] boolValue], @"codex credits: no balance ⇒ exhausted");
            check([empty[@"description"] isEqual:@"No credits (balance 0)"], @"codex credits: names the balance");
            NSDictionary *unlimited = CodexCreditsStatus(@{@"credits": @{@"unlimited": @YES, @"has_credits": @NO}});
            check(![unlimited[@"exhausted"] boolValue], @"codex credits: unlimited is never exhausted");
            NSDictionary *funded = CodexCreditsStatus(@{@"credits": @{@"has_credits": @YES, @"unlimited": @NO,
                                                                      @"balance": @"12.34"}});
            check(![funded[@"exhausted"] boolValue] && [funded[@"description"] containsString:@"12.34"],
                  @"codex credits: a real balance is reported, not flagged");
            // Credits are the one meter with no pair, so they survive a snapshot that omits them.
            NSDictionary *creditless = MergeCodexRateLimits(merged, nullTs,
                                                            @{@"limit_id": @"premium"}, @"2026-08-23T05:00:00.000Z");
            check([CodexCreditsStatus(creditless)[@"exhausted"] boolValue],
                  @"codex merge: credits survive a snapshot that omits them");

            // The accumulator folds every event, so a trailing null snapshot in one
            // batch cannot drop the window seen earlier in that same batch.
            NSArray *events = @[@{@"ts": windowedTs, @"tokens": @10, @"fresh": @5, @"limits": windowed},
                                @{@"ts": nullTs, @"tokens": @0, @"fresh": @0, @"limits": blank}];
            NSDictionary *acc = AccumulateTokenEvents(nil, events, [NSTimeZone timeZoneWithName:@"UTC"]);
            check([acc[@"latestTs"] isEqual:nullTs], @"codex accumulate: latestTs is the newest snapshot");
            check(PickLimitWindow(acc[@"latestLimits"], before) != nil,
                  @"codex accumulate: the window survives a later null snapshot in the same batch");
        }

        // --- CodexSchemaDriftReason ---
        // The line between "understood and empty" and "we can no longer read this".
        {
            NSDictionary *credits = @{@"has_credits": @NO, @"unlimited": @NO, @"balance": @"0"};
            check(CodexSchemaDriftReason(nil) == nil, @"codex drift: no snapshot ⇒ silent");
            check(CodexSchemaDriftReason(@{}) == nil, @"codex drift: empty snapshot ⇒ silent");
            // The real 2026-08-23 payload. Firing here would cry wolf every time an
            // allowance runs out, which is the one moment the row must stay trustworthy.
            check(CodexSchemaDriftReason(@{@"limit_id": @"premium", @"primary": NSNull.null,
                                           @"secondary": NSNull.null, @"credits": credits}) == nil,
                  @"codex drift: explicit nulls beside readable credits are understood");
            check(CodexSchemaDriftReason(@{@"limit_id": @"premium", @"primary": NSNull.null,
                                           @"secondary": NSNull.null}) == nil,
                  @"codex drift: known keys with no values are understood, not drift");
            check([CodexSchemaDriftReason(@{@"primary": @{@"percent_used": @40, @"window_minutes": @300}})
                      isEqual:@"Limit windows changed shape (no used_percent)"],
                  @"codex drift: a renamed field inside a window is caught");
            check([CodexSchemaDriftReason(@{@"credits": @{@"remaining_credits": @5}})
                      isEqual:@"Credit balance changed shape"],
                  @"codex drift: a reshaped credits object is caught");
            check([CodexSchemaDriftReason(@{@"limit_id": @"premium", @"quota_v2": @{@"left": @3}})
                      isEqual:@"Unknown limit fields: quota_v2"],
                  @"codex drift: an unknown top-level field is named");
            check([CodexSchemaDriftReason(@{@"allowance": @1, @"budget": @2, @"quota_v2": @3, @"zebra": @4})
                      isEqual:@"Unknown limit fields: allowance, budget +2"],
                  @"codex drift: short names share the budget, the rest are counted");
            // One long name spends the whole budget, and must not drag a second in after it.
            check([CodexSchemaDriftReason(@{@"spend_envelope": @1, @"weekly_allowance_v2": @2})
                      isEqual:@"Unknown limit fields: spend_envelope +1"],
                  @"codex drift: a long name is reported alone rather than truncated");
            check(CodexSchemaDriftReason(@{@"quota_v2": @{@"left": @3},
                                           @"primary": @{@"used_percent": @40.0}}) == nil,
                  @"codex drift: an unknown field beside a readable meter is not drift");
            // Our own provenance stamp must never read as OpenAI inventing a field.
            check(CodexSchemaDriftReason(@{@"limit_id": @"premium", @"_glancebarObservedAt": @"2026-08-22T02:24:10Z"}) == nil,
                  @"codex drift: Glancebar's own stamp is not an unknown field");
            check([CodexLimitStatusReason(@{@"quota_v2": @{@"left": @3}}, nil, 1000)
                      isEqual:@"Unknown limit fields: quota_v2"],
                  @"codex drift: the status reason reports drift instead of shrugging");
            check([CodexLimitStatusReason(@{@"limit_id": @"premium", @"primary": NSNull.null}, nil, 1000)
                      isEqual:@"Codex session logs do not carry limit status"],
                  @"codex drift: a merely empty snapshot keeps the old, true message");
        }

        // --- Codex merge hardening (findings from an independent review) ---
        {
            double before = 1787479938;
            NSString *tie = @"2026-08-22T02:24:10.143Z";
            // A tie in timestamps must not let dictionary enumeration order decide how
            // much quota the user is told they have.
            NSDictionary *spent = @{@"limit_id": @"codex",
                                    @"primary": @{@"used_percent": @100.0, @"resets_at": @1787802739}};
            NSDictionary *roomy = @{@"limit_id": @"codex",
                                    @"primary": @{@"used_percent": @20.0, @"resets_at": @1787802739}};
            check([PickLimitWindow(MergeCodexRateLimits(spent, tie, roomy, tie), before)[@"remainingFraction"]
                      doubleValue] == 0,
                  @"codex merge: an equal-stamped tie resolves to the more-spent window (incoming first)");
            check([PickLimitWindow(MergeCodexRateLimits(roomy, tie, spent, tie), before)[@"remainingFraction"]
                      doubleValue] == 0,
                  @"codex merge: the same tie resolves the same way from the other side");
            NSDictionary *someCredits = @{@"credits": @{@"has_credits": @YES, @"unlimited": @NO, @"balance": @"9"}};
            NSDictionary *noCredits = @{@"credits": @{@"has_credits": @NO, @"unlimited": @NO, @"balance": @"0"}};
            check([CodexCreditsStatus(MergeCodexRateLimits(someCredits, tie, noCredits, tie))[@"exhausted"] boolValue] &&
                  [CodexCreditsStatus(MergeCodexRateLimits(noCredits, tie, someCredits, tie))[@"exhausted"] boolValue],
                  @"codex merge: a credits tie resolves to exhausted from either side");

            // Carrying a window forward is only safe because it expires on its own, so a
            // reset-less one must not be carried — it would never age out.
            NSDictionary *resetless = @{@"limit_id": @"codex", @"primary": @{@"used_percent": @55.0}};
            NSDictionary *blank2 = @{@"limit_id": @"premium", @"primary": NSNull.null};
            check(PickLimitWindow(MergeCodexRateLimits(resetless, @"2026-08-22T02:24:10.143Z",
                                                       blank2, @"2026-08-23T04:26:27.057Z"), before) == nil,
                  @"codex merge: a reset-less window is not carried past a newer snapshot");
            check(PickLimitWindow(MergeCodexRateLimits(nil, nil, resetless, tie), before) != nil,
                  @"codex merge: a reset-less window from the current snapshot still shows");

            // JSON null appears all over these payloads; the credits reader must not meet
            // it with a scalar selector.
            check(CodexCreditsStatus(@{@"credits": @{@"has_credits": @NO, @"unlimited": NSNull.null}}) != nil,
                  @"codex credits: a null unlimited flag is read, not crashed on");
            check(CodexCreditsStatus(@{@"credits": @{@"has_credits": NSNull.null, @"unlimited": @YES}}) != nil,
                  @"codex credits: a null has_credits beside unlimited still reads");
            check(CodexCreditsStatus(@{@"credits": @{@"has_credits": NSNull.null, @"unlimited": @NO}}) == nil,
                  @"codex credits: with neither flag readable, say nothing rather than guess");
        }

        // --- ResetPhrase / ResetClockText ---
        // The AI row's whole job. Built from calendar components rather than epoch
        // arithmetic so the day-boundary branches are exercised in the local calendar,
        // which is the one the reader is standing in.
        {
            NSCalendar *cal = NSCalendar.currentCalendar;
            NSDate *(^at)(NSInteger, NSInteger, NSInteger) = ^NSDate *(NSInteger day, NSInteger hour, NSInteger minute) {
                NSDateComponents *c = [NSDateComponents new];
                c.year = 2026; c.month = 6; c.day = day; c.hour = hour; c.minute = minute;
                return [cal dateFromComponents:c];
            };
            NSDate *now = at(10, 10, 0);   // Wed 10 June 2026, 10:00 local
            check(ResetPhrase(nil, now) == nil, @"reset: no instant → no phrase");
            check(ResetClockText(nil, now) == nil, @"reset: no instant → no clock text");
            check([ResetPhrase(at(10, 9, 0), now) isEqual:@"Reset has passed"],
                  @"reset: an elapsed cached window says so instead of counting backwards");
            check([ResetPhrase([now dateByAddingTimeInterval:30], now) hasSuffix:@"any moment"],
                  @"reset: under a minute is 'any moment'");
            check([ResetPhrase(at(10, 10, 42), now) hasSuffix:@"in 42m"], @"reset: minutes countdown");
            check([ResetPhrase(at(10, 13, 20), now) hasSuffix:@"in 3h 20m"], @"reset: hours + minutes countdown");
            check([ResetPhrase(at(10, 15, 0), now) hasSuffix:@"in 5h"], @"reset: whole hours drop the minutes");
            check([ResetPhrase(at(10, 15, 0), now) hasPrefix:@"Resets "], @"reset: the phrase leads with the answer");
            NSString *sameDay = ResetClockText(at(10, 15, 0), now);
            check(![sameDay containsString:@"tomorrow"] && sameDay.length <= 8,
                  @"reset: today is a bare clock time");
            NSString *tomorrow = ResetPhrase(at(11, 9, 0), now);
            check([tomorrow containsString:@"tomorrow"] && [tomorrow hasSuffix:@"in 23h"],
                  @"reset: the next calendar day is 'tomorrow', not a weekday");
            NSString *thisWeek = ResetPhrase(at(14, 9, 0), now);
            check([thisWeek hasSuffix:@"in 3d"] && ![thisWeek containsString:@"tomorrow"],
                  @"reset: inside the week counts whole days");
            NSDateFormatter *dayFmt = [NSDateFormatter new];
            [dayFmt setLocalizedDateFormatFromTemplate:@"EEE"];
            check([ResetClockText(at(14, 9, 0), now) hasPrefix:[dayFmt stringFromDate:at(14, 9, 0)]],
                  @"reset: inside the week names the weekday");
            // 11 calendar days out: a weekday would be ambiguous, so the date has to appear.
            check([ResetPhrase(at(21, 9, 0), now) hasSuffix:@"in 10d"], @"reset: beyond a week still counts days");
            check([ResetClockText(at(21, 9, 0), now) containsString:@"21"],
                  @"reset: beyond a week the clock text carries the date");
        }

        fprintf(stderr, "\n%s (%d failure%s)\n", failures ? "TESTS FAILED" : "ALL TESTS PASSED",
                failures, failures == 1 ? "" : "s");
        return failures ? 1 : 0;
    }
}
