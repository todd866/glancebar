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

// Parse `ps -axo pid=,pcpu=,rss=,comm=` output into grouped top CPU and memory apps.
// RSS is returned as bytes. Shape:
// @{@"cpu": @[@{@"name":…, @"cpu":@(…), @"bytes":@(…), @"commands":@[…]}],
//   @"memory": @[…]}.
NSDictionary<NSString *, NSArray<NSDictionary *> *> *ParseProcessStats(NSString *psOutput, int topN,
                                                                        NSString *(^groupForPid)(pid_t));
