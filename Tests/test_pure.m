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
        check([hogs[1][@"name"] isEqual:@"WindowServer"], @"WindowServer second (26.7)");
        check([hogs[2][@"name"] isEqual:@"iTerm2"], @"iTerm2 third (4.0)");
        double ws = 0; for (NSDictionary *h in hogs) if ([h[@"name"] isEqual:@"WindowServer"]) ws = [h[@"impact"] doubleValue];
        check(ws == 26.7, @"WindowServer = 26.7 (second frame only)");

        fprintf(stderr, "\n%s (%d failure%s)\n", failures ? "TESTS FAILED" : "ALL TESTS PASSED",
                failures, failures == 1 ? "" : "s");
        return failures ? 1 : 0;
    }
}
