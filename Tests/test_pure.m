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

        fprintf(stderr, "\n%s (%d failure%s)\n", failures ? "TESTS FAILED" : "ALL TESTS PASSED",
                failures, failures == 1 ? "" : "s");
        return failures ? 1 : 0;
    }
}
