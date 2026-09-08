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

        // --- process naming: a version-numbered executable takes its parent's name ---
        NSDictionary *versioned = ParseProcessStats(
            @"  201 12.0 1000 /Users/x/.local/share/claude/versions/2.1.261\n  202  3.0  500 /usr/bin/top\n  203  1.0  500 node\n", 5,
            ^NSString *(pid_t __unused pid) { return nil; }, nil);
        check([versioned[@"cpu"][0][@"name"] isEqual:@"claude"], @"naming: a version-number basename yields the tool's name");
        check([ProcessNameFromPath(@"/Users/x/.local/share/claude/versions/2.1.261") isEqual:@"claude"] &&
              [ProcessNameFromPath(@"/opt/homebrew/Cellar/node/v22.3.0/bin/node") isEqual:@"node"] &&
              [ProcessNameFromPath(@"/usr/libexec/sysmond") isEqual:@"sysmond"] &&
              [ProcessNameFromPath(@"/x/tool/1.2/bin/2.0") isEqual:@"tool"] &&
              [ProcessNameFromPath(@"2.1.261") isEqual:@"2.1.261"],
              @"naming: version-shaped and structural components are walked past, never everything");
        check([versioned[@"cpu"][1][@"name"] isEqual:@"top"] && [versioned[@"cpu"][2][@"name"] isEqual:@"node"],
              @"naming: ordinary basenames are unchanged");

        // --- FmtDuration ---
        check([FmtDuration(-1) isEqual:@"estimating…"], @"duration: negative minutes are still estimating");
        check([FmtDuration(0) isEqual:@"0:00"] && [FmtDuration(75) isEqual:@"1:15"] && [FmtDuration(605) isEqual:@"10:05"],
              @"duration: h:mm with zero-padded minutes");

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
        // 2026-09 transcript shape: the model rides on the message, tool calls are content
        // blocks, and usage.iterations[] restates the same counters (never double count).
        NSString *cl2 = @"{\"type\":\"assistant\",\"timestamp\":\"2026-09-07T06:05:49.980Z\",\"message\":{\"id\":\"msg_1\",\"model\":\"claude-fable-5-1\",\"content\":[{\"type\":\"text\",\"text\":\"x\"},{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\"},{\"type\":\"tool_use\",\"id\":\"t2\",\"name\":\"Read\"}],\"usage\":{\"input_tokens\":32,\"cache_creation_input_tokens\":4689,\"cache_read_input_tokens\":174555,\"output_tokens\":2372,\"output_tokens_details\":{\"thinking_tokens\":808},\"iterations\":[{\"input_tokens\":32,\"output_tokens\":2372,\"cache_read_input_tokens\":174555}]}}}";
        NSDictionary *cev2 = ParseClaudeUsageLine(cl2);
        check([cev2[@"model"] isEqual:@"claude-fable-5-1"], @"claude model id surfaced");
        check([cev2[@"tools"] longLongValue] == 2, @"claude tool_use blocks counted");
        check([cev2[@"fresh"] longLongValue] == 32 + 2372, @"claude iterations[] is not double counted");
        check(cev[@"model"] == nil || [cev[@"model"] isEqual:@"claude-fable-5"], @"claude model optional");
        check(cev[@"tools"] == nil, @"claude line without content has no tools key");

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
        // Per-day activity counters: messages, tool calls, and a per-model fresh split.
        NSDictionary *acc3 = AccumulateTokenEvents(nil, @[
            @{@"ts": @"2026-06-10T01:00:00Z", @"tokens": @100, @"fresh": @10, @"model": @"a", @"tools": @2},
            @{@"ts": @"2026-06-10T02:00:00Z", @"tokens": @5, @"fresh": @5, @"model": @"b"},
            @{@"ts": @"2026-06-10T03:00:00Z", @"tokens": @1, @"fresh": @1, @"model": @"a"},
            @{@"ts": @"2026-06-10T04:00:00Z", @"tokens": @0, @"fresh": @0, @"model": @"a",
              @"limits": @{@"plan_type": @"prolite"}},
        ], tz);
        NSDictionary *day = acc3[@"days"][@"2026-06-10"];
        check([day[@"n"] longLongValue] == 3, @"events with tokens count as messages; a limits-only event does not");
        check([day[@"c"] longLongValue] == 2, @"tool calls summed per day");
        check([day[@"m"][@"a"] longLongValue] == 11 && [day[@"m"][@"b"] longLongValue] == 5,
              @"fresh tokens split per model");
        check(acc2[@"days"][@"2026-06-10"][@"m"] == nil, @"events without a model add no model map");
        NSDictionary *acc4 = AccumulateTokenEvents(acc3[@"days"],
            @[@{@"ts": @"2026-06-10T05:00:00Z", @"tokens": @2, @"fresh": @2, @"model": @"b", @"tools": @1}], tz);
        NSDictionary *day4 = acc4[@"days"][@"2026-06-10"];
        check([day4[@"n"] longLongValue] == 4 && [day4[@"c"] longLongValue] == 3 &&
              [day4[@"m"][@"b"] longLongValue] == 7 && [day4[@"m"][@"a"] longLongValue] == 11,
              @"activity counters merge into existing days");
        check([acc3[@"buckets"][@"codex"][@"limits"][@"plan_type"] isEqual:@"prolite"],
              @"limits without a limit_id land in the codex bucket");
        check([acc3[@"newestLimits"][@"plan_type"] isEqual:@"prolite"] &&
              [acc3[@"newestTs"] isEqual:@"2026-06-10T04:00:00Z"], @"newest snapshot kept verbatim");
        NSDictionary *acc5 = AccumulateTokenEvents(nil, @[
            @{@"ts": @"2026-06-10T01:00:00Z", @"tokens": @10, @"fresh": @3, @"model": @"a", @"tools": @1},
            @{@"ts": @"2026-06-10T01:00:02Z", @"tokens": @300, @"fresh": @384, @"model": @"a", @"tools": @1, @"amend": @YES},
            @{@"ts": @"2026-06-10T01:00:03Z", @"tokens": @0, @"fresh": @0, @"model": @"a", @"tools": @1, @"amend": @YES},
        ], tz);
        NSDictionary *day5 = acc5[@"days"][@"2026-06-10"];
        check([day5[@"n"] longLongValue] == 1 && [day5[@"f"] longLongValue] == 387 && [day5[@"c"] longLongValue] == 3 &&
              [day5[@"m"][@"a"] longLongValue] == 387,
              @"an amendment adds tokens and tool calls without counting another message");
        NSDictionary *summed = MergeDayCounts(@{@"t": @1, @"f": @1, @"m": @{@"x": @1}}, nil);
        check([summed[@"t"] longLongValue] == 1 && [summed[@"m"][@"x"] longLongValue] == 1 && summed[@"n"] == nil,
              @"MergeDayCounts tolerates a missing side and omits zero counters");

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
        check(ClaudeLimitStatusReason(nil, @"", 1000) == nil && CursorLimitStatusReason(nil, @"", 1000) == nil,
              @"no response at all is not 'no current limit window' — the caller explains that");
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

        // --- Codex limit buckets (limit_id) ---
        // Shapes taken verbatim from ~/.codex rollouts on 2026-09-07: the plan bucket's
        // weekly window (in the PRIMARY slot, no secondary) climbed to 99% while a side
        // bucket reported 0%/0% in the same sessions seconds apart, and the next snapshot
        // arrived under "premium" with both windows null and no credits.
        {
            NSDictionary *noCredits = @{@"has_credits": @NO, @"unlimited": @NO, @"balance": @"0"};
            NSDictionary *plan = @{@"limit_id": @"codex", @"plan_type": @"pro", @"credits": noCredits,
                                   @"primary": @{@"used_percent": @99.0, @"window_minutes": @10080,
                                                 @"resets_at": @1789167190},
                                   @"secondary": NSNull.null};
            NSDictionary *fox = @{@"limit_id": @"codex_bengalfox", @"plan_type": @"pro", @"credits": noCredits,
                                  @"primary": @{@"used_percent": @0.0, @"window_minutes": @300,
                                                @"resets_at": @1788778395},
                                  @"secondary": @{@"used_percent": @0.0, @"window_minutes": @10080,
                                                  @"resets_at": @1789365195}};
            NSDictionary *premium = @{@"limit_id": @"premium", @"plan_type": @"pro", @"credits": noCredits,
                                      @"primary": NSNull.null, @"secondary": NSNull.null};
            NSString *planTs = @"2026-09-07T05:45:58.309Z", *foxTs = @"2026-09-07T05:53:27.384Z",
                     *premiumTs = @"2026-09-07T05:54:01.194Z";
            double now = 1788761000;   // 2026-09-07T06:03Z

            check([CodexLimitBucketID(plan) isEqual:@"codex"] && [CodexLimitBucketID(@{}) isEqual:@"codex"],
                  @"buckets: limit_id names the bucket, absent means the plan bucket");
            check([CodexBucketLabel(@"codex") isEqual:@"plan"] && [CodexBucketLabel(@"premium") isEqual:@"credits"] &&
                  [CodexBucketLabel(@"codex_bengalfox") isEqual:@"bengalfox"] && [CodexBucketLabel(@"other") isEqual:@"other"],
                  @"buckets: labels are short and human");

            NSDictionary *b = FoldCodexSnapshotIntoBuckets(nil, plan, planTs);
            b = FoldCodexSnapshotIntoBuckets(b, fox, foxTs);
            b = FoldCodexSnapshotIntoBuckets(b, premium, premiumTs);
            check(b.count == 3, @"buckets: one entry per limit_id");
            NSDictionary *pick = PickCodexBucketWindow(b, now);
            check([pick[@"bucket"] isEqual:@"codex"] && [pick[@"window"] isEqual:@"weekly"],
                  @"buckets: the spent plan window governs, not the newest untouched bucket");
            check(fabs([pick[@"remainingFraction"] doubleValue] - 0.01) < 0.001, @"buckets: 1% left");
            check([pick[@"resetsAt"] doubleValue] == 1789167190 && [pick[@"plan"] isEqual:@"pro"],
                  @"buckets: the pick keeps the window's own reset and plan");
            check([pick[@"bucketLabel"] isEqual:@"plan"], @"buckets: the pick is labeled");
            NSArray *wins = CodexBucketWindows(b, now);
            check(wins.count == 3, @"buckets: every current window across buckets is listed");
            check([wins[0][@"bucket"] isEqual:@"codex"], @"buckets: most constrained bucket first");
            check([wins[1][@"bucketLabel"] isEqual:@"bengalfox"] && [wins[1][@"window"] isEqual:@"5-hour"] &&
                  [wins[2][@"bucketLabel"] isEqual:@"bengalfox"] && [wins[2][@"window"] isEqual:@"weekly"],
                  @"buckets: other buckets follow, primary before secondary");
            check([CodexNewestBucketID(b) isEqual:@"premium"], @"buckets: newest snapshot names where requests bill now");
            check([CodexNewestBucketLimits(b)[@"limit_id"] isEqual:@"premium"], @"buckets: newest limits are the premium snapshot");
            check([CodexBillingNote(b, now) isEqual:@"Requests now bill to credits · none available"],
                  @"buckets: billing note says the plan is spent and no credits remain");
            check(CodexBucketsStatusReason(b, now) == nil, @"buckets: a current window means no fallback reason");

            // Fold order must not change anything.
            NSDictionary *r = FoldCodexSnapshotIntoBuckets(nil, premium, premiumTs);
            r = FoldCodexSnapshotIntoBuckets(r, fox, foxTs);
            r = FoldCodexSnapshotIntoBuckets(r, plan, planTs);
            check([PickCodexBucketWindow(r, now)[@"bucket"] isEqual:@"codex"], @"buckets: fold order does not change the pick");
            check([CodexNewestBucketID(r) isEqual:@"premium"], @"buckets: fold order does not change the newest bucket");
            // Union of two maps (records from different files) is a per-bucket merge.
            NSDictionary *u = MergeCodexLimitBuckets(FoldCodexSnapshotIntoBuckets(nil, plan, planTs),
                                                     FoldCodexSnapshotIntoBuckets(nil, fox, foxTs));
            check(u.count == 2 && [PickCodexBucketWindow(u, now)[@"bucket"] isEqual:@"codex"],
                  @"buckets: merging maps keeps both buckets and the spent one still governs");
            NSDictionary *fresher = @{@"limit_id": @"codex", @"plan_type": @"pro",
                                      @"primary": @{@"used_percent": @12.0, @"window_minutes": @10080,
                                                    @"resets_at": @1789772000}};
            NSDictionary *u2 = MergeCodexLimitBuckets(u, FoldCodexSnapshotIntoBuckets(nil, fresher, @"2026-09-12T08:00:00.000Z"));
            check(fabs([PickCodexBucketWindow(u2, 1789200000)[@"remainingFraction"] doubleValue] - 0.88) < 0.001,
                  @"buckets: within a bucket the newer reading wins");
            check(MergeCodexLimitBuckets(nil, nil) == nil && [MergeCodexLimitBuckets(u, nil) count] == 2,
                  @"buckets: merge tolerates nil");
            // Legacy null-window carry-forward still works inside one bucket.
            NSDictionary *carried = FoldCodexSnapshotIntoBuckets(
                FoldCodexSnapshotIntoBuckets(nil, plan, planTs),
                @{@"limit_id": @"codex", @"primary": NSNull.null, @"secondary": NSNull.null}, premiumTs);
            check([PickCodexBucketWindow(carried, now)[@"resetsAt"] doubleValue] == 1789167190,
                  @"buckets: a null-window snapshot in the same bucket cannot erase the known window");

            // After the plan window resets, the side bucket is what remains current.
            check([PickCodexBucketWindow(b, 1789167200)[@"bucket"] isEqual:@"codex_bengalfox"],
                  @"buckets: once the plan window resets, the side bucket governs");
            check(CodexBillingNote(b, 1789167200) != nil, @"buckets: billing note persists while premium is newest");
            // When every window has reset, say so, dated from the bucket that carried windows.
            check(PickCodexBucketWindow(b, 1790000000) == nil, @"buckets: all-expired yields no pick");
            check([CodexBucketsStatusReason(b, 1790000000) hasPrefix:@"Limit windows reset since last Codex session"],
                  @"buckets: all-expired names the reset, not a missing source");
            check(CodexBucketWindows(nil, now).count == 0 && PickCodexBucketWindow(nil, now) == nil,
                  @"buckets: nil map is empty");
            check([CodexBucketsStatusReason(nil, now) isEqual:@"Codex session logs do not carry limit status"],
                  @"buckets: no buckets ever means no source");
        }

        // --- ClaudeLimitWindows: the 2026-09 `limits` array ---
        {
            NSDictionary *live = @{
                @"limits": @[
                    @{@"kind": @"session", @"group": @"session", @"is_active": @YES, @"percent": @7,
                      @"resets_at": @"2026-09-07T10:49:59.601495+00:00", @"scope": NSNull.null, @"severity": @"normal"},
                    @{@"kind": @"weekly_all", @"group": @"weekly", @"is_active": @NO, @"percent": @2,
                      @"resets_at": @"2026-09-08T12:59:59.601557+00:00", @"scope": NSNull.null},
                    @{@"kind": @"weekly_scoped", @"group": @"weekly", @"is_active": @NO, @"percent": @3,
                      @"resets_at": @"2026-09-08T12:59:59.601909+00:00",
                      @"scope": @{@"model": @{@"id": NSNull.null, @"display_name": @"Fable"}, @"surface": NSNull.null}}],
                @"five_hour": @{@"utilization": @7, @"resets_at": @"2026-09-07T10:49:59.601495+00:00"},
                @"seven_day": @{@"utilization": @2, @"resets_at": @"2026-09-08T12:59:59.601557+00:00"},
                @"seven_day_opus": NSNull.null, @"nimbus_quill": @{@"utilization": @0, @"resets_at": NSNull.null}};
            double now = 1788761000;   // 2026-09-07T06:03Z
            NSArray *w = ClaudeLimitWindows(live, now);
            check(w.count == 3, @"limits[]: all three windows surface");
            check([w[0][@"window"] isEqual:@"5-hour"] && fabs([w[0][@"remainingFraction"] doubleValue] - 0.93) < 0.001,
                  @"limits[]: session is the 5-hour window");
            check([w[1][@"window"] isEqual:@"weekly"] && fabs([w[1][@"remainingFraction"] doubleValue] - 0.98) < 0.001,
                  @"limits[]: weekly_all is the weekly window");
            check([w[2][@"window"] isEqual:@"weekly Fable"] && fabs([w[2][@"remainingFraction"] doubleValue] - 0.97) < 0.001,
                  @"limits[]: the model-scoped weekly is named after its model");
            check([w[0][@"active"] boolValue] && ![w[1][@"active"] boolValue] && [w[2][@"kind"] isEqual:@"weekly_scoped"],
                  @"limits[]: kind and is_active ride along");
            check(fabs([w[1][@"resetsAt"] doubleValue] - 1788872399.6) < 1, @"limits[]: microsecond ISO resets parse");
            check([PickClaudeLimitWindow(live, now)[@"window"] isEqual:@"5-hour"], @"limits[]: most constrained wins");
            check(ClaudeLimitStatusReason(live, @"2026-09-07T06:08:45Z", now) == nil, @"limits[]: live windows need no reason");
            NSArray *elapsed = ClaudeStaleLimitWindows(live, 1789000000);
            check(elapsed.count == 3 && [elapsed[2][@"window"] isEqual:@"weekly Fable"], @"limits[]: elapsed set keeps names");

            // A fresh week (2026-09-05 shape): every window reset-less with nothing used.
            NSDictionary *fresh = @{
                @"limits": @[
                    @{@"kind": @"session", @"is_active": @YES, @"percent": @0, @"resets_at": NSNull.null},
                    @{@"kind": @"weekly_all", @"is_active": @NO, @"percent": @0, @"resets_at": NSNull.null},
                    @{@"kind": @"weekly_scoped", @"is_active": @NO, @"percent": @0, @"resets_at": NSNull.null,
                      @"scope": @{@"model": @{@"display_name": @"Fable"}}}],
                @"five_hour": @{@"utilization": @0, @"resets_at": NSNull.null},
                @"seven_day": @{@"utilization": @0, @"resets_at": NSNull.null}};
            NSArray *fw = ClaudeLimitWindows(fresh, now);
            check(fw.count == 3, @"limits[]: an unused account still has windows to show");
            check([fw[0][@"fresh"] boolValue] && [fw[0][@"remainingFraction"] doubleValue] == 1.0 && fw[0][@"resetsAt"] == nil,
                  @"limits[]: an unused window is 100% left with no reset yet");
            check([PickClaudeLimitWindow(fresh, now)[@"fresh"] boolValue], @"limits[]: the pick says it is fresh");
            check(ClaudeLimitStatusReason(fresh, nil, now) == nil, @"limits[]: fresh windows count as current, not 'no window'");
            check(ClaudeStaleLimitWindows(fresh, now).count == 0, @"limits[]: fresh windows are never stale");
            // Legacy-only fresh shape (an older cached response) gets the same treatment.
            NSDictionary *legacyFresh = @{@"five_hour": @{@"utilization": @0, @"resets_at": NSNull.null},
                                          @"seven_day": @{@"utilization": @0, @"resets_at": NSNull.null}};
            check(ClaudeLimitWindows(legacyFresh, now).count == 2, @"legacy fresh shape shows two unused windows");
            // A lone reset-less entry beside live windows is a placeholder and stays hidden.
            NSDictionary *mixed = @{@"limits": @[
                @{@"kind": @"session", @"percent": @7, @"resets_at": @9000000000},
                @{@"kind": @"weekly_scoped", @"percent": @0, @"resets_at": NSNull.null,
                  @"scope": @{@"model": @{@"display_name": @"Opus"}}}]};
            NSArray *mw = ClaudeLimitWindows(mixed, now);
            check(mw.count == 1 && [mw[0][@"window"] isEqual:@"5-hour"], @"limits[]: an unused scoped weekly beside a live window stays hidden");
            check(ClaudeLimitWindows(@{@"limits": @[@{@"kind": @"weekly_all", @"percent": @5, @"resets_at": NSNull.null}]}, now).count == 0,
                  @"limits[]: used-but-reset-less is a placeholder, not fresh");
            // Units: percent 1 is 1%.
            NSArray *one = ClaudeLimitWindows(@{@"limits": @[@{@"kind": @"weekly_all", @"percent": @1, @"resets_at": @9000000000}]}, now);
            check(one.count == 1 && fabs([one[0][@"remainingFraction"] doubleValue] - 0.99) < 0.001,
                  @"limits[]: percent 1 is 1% used, never fully used");
            // The array wins over legacy dicts when both are present.
            NSDictionary *disagree = @{@"limits": @[@{@"kind": @"session", @"percent": @50, @"resets_at": @9000000000}],
                                       @"five_hour": @{@"utilization": @10, @"resets_at": @9000000000}};
            check(fabs([ClaudeLimitWindows(disagree, now)[0][@"remainingFraction"] doubleValue] - 0.5) < 0.001,
                  @"limits[]: the array is authoritative over the legacy mirror");
            // An unreadable array falls back to the legacy dicts.
            NSDictionary *unreadable = @{@"limits": @[@{@"kind": @"session", @"percent": @"seven"}],
                                         @"five_hour": @{@"utilization": @10, @"resets_at": @9000000000}};
            check(ClaudeLimitWindows(unreadable, now).count == 1, @"limits[]: an unreadable array falls back to legacy");
            // Unknown kinds name themselves; an entry with no kind is skipped.
            NSArray *odd = ClaudeLimitWindows(@{@"limits": @[@{@"kind": @"monthly_all", @"percent": @50, @"resets_at": @9000000000},
                                                              @{@"percent": @50, @"resets_at": @9000000000}]}, now);
            check(odd.count == 1 && [odd[0][@"window"] isEqual:@"monthly all"], @"limits[]: unknown kinds still name themselves");
            // A scoped weekly with no model name still has a label.
            NSArray *noName = ClaudeLimitWindows(@{@"limits": @[@{@"kind": @"weekly_scoped", @"percent": @1, @"resets_at": @9000000000}]}, now);
            check([noName[0][@"window"] isEqual:@"weekly (model)"], @"limits[]: scoped weekly without a name is still labeled");

            // Extra usage that is switched off explains itself as context only.
            NSDictionary *off = ClaudeExtraUsageStatus(@{@"extra_usage": @{@"is_enabled": @NO, @"disabled_reason": @"out_of_credits",
                                                                         @"monthly_limit": @20000, @"currency": @"AUD"}});
            check([off[@"description"] isEqual:@"Off · out of credits"] && off[@"statusReason"] == nil && ![off[@"overageActive"] boolValue],
                  @"extra_usage off: description only, no status, no overage");
        }

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
        check([kcExpired[@"status"] isEqual:@"Claude Code token expired · open Claude Code to refresh it"],
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

        // --- GUIRequiresLaunchServicesRelaunch ---
        check(!GUIRequiresLaunchServicesRelaunch(@"com.iantodd.glancebar",
                                                 @"com.iantodd.glancebar"),
              @"launch guard: matching Launch Services identity is accepted");
        check(GUIRequiresLaunchServicesRelaunch(nil, @"com.iantodd.glancebar"),
              @"launch guard: direct executable launch is relaunched");
        check(GUIRequiresLaunchServicesRelaunch(@"com.openai.codex",
                                                @"com.iantodd.glancebar"),
              @"launch guard: foreign parent attribution is relaunched");
        check(!GUIRequiresLaunchServicesRelaunch(@"com.iantodd.glancebar", nil),
              @"launch guard: malformed bundle identity is handled by the caller");

        // --- Bar: an abutting left neighbour is the normal layout, not a squeeze ---
        {
            // Control Centre lays hosts edge to edge: neighbour 1023..1063, self 1063..1191.
            const BarWindowSpan packed[] = { {1023, 40}, {1063, 128}, {1191, 38} };
            double cap = BarCapacityFromWindowSpans(825, 1470, (BarWindowSpan){1063, 128}, packed, 3);
            check(fabs(cap - 128) < 0.001, @"packed: capacity is exactly our own span");
            const double OCC[kBarTierCount] = {128, 82, 51, 38};
            BarTierState held = ChooseBarTier((BarTierState){BarTierFull, 0, 0}, cap, OCC, NO, 100);
            check(held.tier == BarTierFull, @"packed: an item that is on the bar already fits — no shrink");
            // One point of compositor rounding either way must not shrink us either.
            check(ChooseBarTier((BarTierState){BarTierFull, 0, 0}, 127.2, OCC, NO, 100).tier == BarTierFull,
                  @"packed: sub-point rounding is tolerated");
            // A neighbour that has actually moved INTO our span is a real squeeze.
            const BarWindowSpan squeezed[] = { {1023, 46}, {1063, 128}, {1191, 38} };
            double squeezedCap = BarCapacityFromWindowSpans(825, 1470, (BarWindowSpan){1063, 128}, squeezed, 3);
            check(fabs(squeezedCap - 122) < 0.001, @"packed: a 6pt overlap is an obstacle, not ignored");
            check(ChooseBarTier((BarTierState){BarTierFull, 0, 0}, squeezedCap, OCC, NO, 100).tier == BarTierText,
                  @"packed: a real overlap steps down one rung, keeping both readings");
            // And the fallback tier must itself fit with margin.
            check(ChooseBarTier((BarTierState){BarTierFull, 0, 0}, 56, OCC, NO, 100).tier == BarTierCompact,
                  @"packed: shrink lands on the widest rung that fits with margin (51+4<=56)");
            check(ChooseBarTier((BarTierState){BarTierFull, 0, 0}, 52, OCC, NO, 100).tier == BarTierGlyph,
                  @"packed: shrink skips a rung that would fit without margin (51+4>52)");
        }

        // --- BarEvictionSuspected: arm-after-seen, with a launch grace ---
        check(!BarEvictionSuspected(NO, NO, 5), @"eviction: an unseen item inside the grace is not evicted");
        check(BarEvictionSuspected(NO, NO, kBarEvictionGraceSec), @"eviction: never seen after the grace counts as evicted");
        check(BarEvictionSuspected(YES, NO, 0), @"eviction: a fall from the bar is eviction at once");
        check(!BarEvictionSuspected(YES, YES, 1000) && !BarEvictionSuspected(NO, YES, 1000),
              @"eviction: on the bar is never evicted");

        // --- ChooseBarTier ---
        {
            // Tahoe renders app status items in Control Centre-owned host windows, so
            // the visible self can have a different window number from the app-side
            // NSWindow. Geometry must exclude both the full and compact hosted spans
            // and leave the same genuine-neighbour capacity in either state.
            const BarWindowSpan fullHosts[] = {
                {939, 131},   // Glancebar Full host (self)
                {1070, 38},   // first genuine neighbour
                {1108, 67},
            };
            double fullCapacity = BarCapacityFromWindowSpans(
                825, 1470, (BarWindowSpan){939, 131}, fullHosts,
                sizeof(fullHosts) / sizeof(fullHosts[0]));
            check(fabs(fullCapacity - 245) < 0.001,
                  @"capacity: excludes Tahoe-hosted Full self by overlap");

            const BarWindowSpan compactHosts[] = {
                {1019, 51},   // the same Glancebar host after Compact redraw (self)
                {1070, 38},
                {1108, 67},
            };
            double compactCapacity = BarCapacityFromWindowSpans(
                825, 1470, (BarWindowSpan){1019, 51}, compactHosts,
                sizeof(compactHosts) / sizeof(compactHosts[0]));
            check(fabs(compactCapacity - 245) < 0.001,
                  @"capacity: Compact redraw does not change available strip width");
            const BarWindowSpan wrappedHosts[] = {
                {935, 137},   // differently sized Control Centre wrapper for self
                {1070, 38},
            };
            check(fabs(BarCapacityFromWindowSpans(825, 1470,
                                                  (BarWindowSpan){939, 131},
                                                  wrappedHosts, 2) - 245) < 0.001,
                  @"capacity: substantially overlapping wrapper is also self");
            const BarWindowSpan leftNeighbour[] = {
                {900, 40},    // one-point compositor overlap at the left edge
                {939, 131},   // self
                {1070, 38},
            };
            check(fabs(BarCapacityFromWindowSpans(825, 1470,
                                                  (BarWindowSpan){939, 131},
                                                  leftNeighbour, 3) - 130) < 0.001,
                  @"capacity: rounded left neighbour limits growth instead of looking like self");
            check(fabs(BarCapacityFromWindowSpans(825, 1470,
                                                  (BarWindowSpan){939, 131},
                                                  NULL, 0) - 245) < 0.001,
                  @"capacity: zero candidate spans still use the live own frame");
            check(BarCapacityFromWindowSpans(825, 1470, (BarWindowSpan){939, 131},
                                             NULL, 1) < 0,
                  @"capacity: nonzero span count requires a span array");
            const BarWindowSpan notchlessHosts[] = {
                {0, 300},     // application menus to the left
                {1000, 50},   // self
                {1050, 38},
            };
            double notchlessCapacity = BarCapacityFromWindowSpans(
                0, 1470, (BarWindowSpan){1000, 50}, notchlessHosts, 3);
            check(fabs(notchlessCapacity - 750) < 0.001,
                  @"capacity: notchless display grows from the nearest left obstacle");
            check(BarCapacityFromWindowSpans(825, 825, (BarWindowSpan){939, 131},
                                             fullHosts, 3) < 0,
                  @"capacity: invalid screen geometry is unknown");
            check(BarCapacityFromWindowSpans(825, 1470, (BarWindowSpan){800, 50},
                                             fullHosts, 3) < 0,
                  @"capacity: stale own span outside the target display is unknown");

            // full, text (readings without icons), compact (one reading), glyph — points.
            const double W[kBarTierCount] = {121, 88, 55, 22};
            const double T = 10000;              // arbitrary epoch base for the clock
            double t = T;
            BarTierState s = {BarTierFull, 0, 0};
            // Plenty of room: stays full, no streak.
            s = ChooseBarTier(s, 200, W, NO, t);
            check(s.tier == BarTierFull && s.expandStreak == 0, @"tier: roomy gap holds full");
            const double LIVE_W[kBarTierCount] = {115, 66, 35, 19};
            s = (BarTierState){BarTierFull, 0, 0};
            s = ChooseBarTier(s, fullCapacity, LIVE_W, NO, t);
            check(s.tier == BarTierFull,
                  @"tier: live Tahoe capacity keeps the two-meter Full bar");
            const double LIVE_OCCUPIED_W[kBarTierCount] = {131, 82, 51, 35};
            s = (BarTierState){BarTierFull, 0, 0};
            s = ChooseBarTier(s, 130, LIVE_OCCUPIED_W, NO, t);
            check(s.tier == BarTierFull,
                  @"tier: a one-point compositor overlap on a 131pt host is rounding, not a squeeze");
            s = (BarTierState){BarTierFull, 0, 0};
            s = ChooseBarTier(s, 126, LIVE_OCCUPIED_W, NO, t);
            check(s.tier == BarTierText,
                  @"tier: a real squeeze gives up the icons first, not the readings");
            s = (BarTierState){BarTierText, 0, 0};
            s = ChooseBarTier(s, notchlessCapacity, LIVE_W, NO, t += 15);
            s = ChooseBarTier(s, notchlessCapacity, LIVE_W, NO, t += 15);
            check(s.tier == BarTierFull,
                  @"tier: a roomy notchless display recovers from Text");
            // Gap collapses to 31 pt (the 2026-08-12 incident): straight to glyph.
            s = ChooseBarTier(s, 31, W, NO, t += 15);
            check(s.tier == BarTierGlyph, @"tier: 31pt gap shrinks past compact to glyph");
            // Gap that fits compact exactly with shrink margin picks compact, not glyph.
            s = (BarTierState){BarTierFull, 0, 0};
            s = ChooseBarTier(s, 60, W, NO, t += 15);
            check(s.tier == BarTierCompact, @"tier: 60pt gap fits compact (55+4<=60)");
            // The point of the Text rung: a gap that kills Full still keeps both readings.
            s = (BarTierState){BarTierFull, 0, 0};
            s = ChooseBarTier(s, 95, W, NO, t += 15);
            check(s.tier == BarTierText, @"tier: 95pt gap keeps every reading, minus the icons");
            // Nothing fits: glyph is the floor — never voluntarily hidden.
            s = (BarTierState){BarTierGlyph, 0, 0};
            s = ChooseBarTier(s, 10, W, NO, t += 15);
            check(s.tier == BarTierGlyph, @"tier: glyph floor even when glyph overflows");
            // A tiny deadband remains: compact fits for shrinking, but not yet with the
            // 8pt recovery margin, so a gap hovering at the boundary cannot flap us.
            s = (BarTierState){BarTierGlyph, 0, 0};
            for (int i = 0; i < 3; i++) s = ChooseBarTier(s, 62, W, NO, t += 15);
            check(s.tier == BarTierGlyph && s.expandStreak == 0, @"tier: boundary fit does not flap wider");
            // With modest slack (55+8<=63): expands after exactly kBarExpandTicks counted decisions.
            s = (BarTierState){BarTierGlyph, 0, 0};
            s = ChooseBarTier(s, 63, W, NO, t += 15);
            check(s.tier == BarTierGlyph && s.expandStreak == 1, @"tier: first slack tick only counts");
            s = ChooseBarTier(s, 63, W, NO, t += 15);
            check(s.tier == BarTierCompact && s.expandStreak == 0, @"tier: second slack tick expands one rung");
            // THE BURST GUARD: updateBar fires many times per second during IOPS bursts.
            // Qualifying decisions closer together than kBarExpandMinIntervalSec must not
            // count, or a 30-second promise collapses into milliseconds (observed live).
            s = (BarTierState){BarTierGlyph, 0, 0};
            s = ChooseBarTier(s, 63, W, NO, t += 15);
            check(s.expandStreak == 1, @"tier: burst — first decision counts");
            for (int i = 0; i < 20; i++) s = ChooseBarTier(s, 63, W, NO, t += 0.01);
            check(s.tier == BarTierGlyph && s.expandStreak == 1,
                  @"tier: burst of 20 qualifying decisions in 0.2s cannot expand");
            s = ChooseBarTier(s, 63, W, NO, t += kBarExpandMinIntervalSec);
            check(s.tier == BarTierCompact, @"tier: expands once the wall clock actually advances");
            // An interruption resets the streak.
            s = (BarTierState){BarTierGlyph, 0, 0};
            s = ChooseBarTier(s, 63, W, NO, t += 15);
            s = ChooseBarTier(s, -1, W, NO, t += 15);
            check(s.tier == BarTierGlyph && s.expandStreak == 0, @"tier: unknown gap holds tier, resets streak");
            s = ChooseBarTier(s, 63, W, NO, t += 15);
            check(s.tier == BarTierGlyph && s.expandStreak == 1, @"tier: streak restarts after reset");
            // Eviction overrides a (stale) roomy measurement.
            s = (BarTierState){BarTierFull, 1, 0};
            s = ChooseBarTier(s, 500, W, YES, t += 15);
            check(s.tier == BarTierGlyph && s.expandStreak == 0, @"tier: eviction forces glyph despite roomy gap");
            // The old 24pt recovery margin trapped compact mode after one neighboring
            // icon appeared and disappeared. A previously comfortable 130pt gap now
            // restores Full after the normal two time-spaced confirmations.
            s = (BarTierState){BarTierFull, 0, 0};
            s = ChooseBarTier(s, 100, W, NO, t += 15);
            check(s.tier == BarTierText,
                  @"tier: temporary pressure now costs the icons, not a reading (88+4<=100)");
            s = ChooseBarTier(s, 130, W, NO, t += 15);
            check(s.tier == BarTierText && s.expandStreak == 1,
                  @"tier: restored one-icon gap starts recovery");
            s = ChooseBarTier(s, 130, W, NO, t += 15);
            check(s.tier == BarTierFull, @"tier: restored one-icon gap returns to full");
            // Recovery from glyph remains one rung per step: glyph→compact→text→full.
            s = (BarTierState){BarTierGlyph, 0, 0};
            for (int i = 0; i < 2; i++) s = ChooseBarTier(s, 500, W, NO, t += 15);
            check(s.tier == BarTierCompact, @"tier: recovery step 1 lands compact");
            for (int i = 0; i < 2; i++) s = ChooseBarTier(s, 500, W, NO, t += 15);
            check(s.tier == BarTierText, @"tier: recovery step 2 lands text");
            for (int i = 0; i < 2; i++) s = ChooseBarTier(s, 500, W, NO, t += 15);
            check(s.tier == BarTierFull, @"tier: recovery step 3 lands full");
            // A degenerate width vector (a tier that measures wider than the one below it)
            // must still terminate at a real tier, never spin or overrun the array.
            const double DEGEN[kBarTierCount] = {18, 4, 9, 22};
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
