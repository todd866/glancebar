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
            ^NSString *(pid_t pid) { return nil; },
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
        NSDictionary *cpick2 = PickClaudeLimitWindow(@{@"five_hour": @{@"utilization": @0.4, @"resets_at": @9000}}, 1000);
        check(fabs([cpick2[@"remainingFraction"] doubleValue] - 0.6) < 0.001, @"fraction utilization tolerated");
        check(PickClaudeLimitWindow(@{@"five_hour": @{@"utilization": @37, @"resets_at": @500}}, 1000) == nil,
              @"claude obsolete window skipped");
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

        // --- RateLimitRetryDelay ---
        check(RateLimitRetryDelay(0) == 900, @"no Retry-After ⇒ 900s floor");
        check(RateLimitRetryDelay(600) == 900, @"short Retry-After ⇒ 900s floor");
        check(RateLimitRetryDelay(2000) == 2000, @"reasonable Retry-After honored");
        check(RateLimitRetryDelay(86400) == 3600, @"huge Retry-After capped at 3600s");

        fprintf(stderr, "\n%s (%d failure%s)\n", failures ? "TESTS FAILED" : "ALL TESTS PASSED",
                failures, failures == 1 ? "" : "s");
        return failures ? 1 : 0;
    }
}
