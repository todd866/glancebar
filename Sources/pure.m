#import "pure.h"

int MinutesTo20(BatteryState b, double avgAmp_mA) {
    if (b.acConnected || b.isCharging || b.percent <= 20) return -1;
    if (b.minutesToEmpty > 0 && b.percent > 0) {
        double frac = (double)(b.percent - 20) / (double)b.percent;
        return (int)lround(b.minutesToEmpty * frac);
    }
    if (avgAmp_mA < -1 && b.rawMax_mAh > 0 && b.rawCurrent_mAh > 0) {
        double headroom = b.rawCurrent_mAh - 0.20 * b.rawMax_mAh;
        if (headroom <= 0) return 0;
        double hours = headroom / (-avgAmp_mA);
        return (int)lround(hours * 60.0);
    }
    return -1;
}

NSString *FmtDuration(int minutes) {
    if (minutes < 0) return @"estimating…";
    return [NSString stringWithFormat:@"%d:%02d", minutes / 60, minutes % 60];
}

NSArray<NSDictionary *> *ParseHogs(NSString *topOutput, int topN,
                                   NSString *(^groupForPid)(pid_t)) {
    NSArray<NSString *> *lines = [topOutput componentsSeparatedByString:@"\n"];
    NSInteger headerCount = 0, start = -1;
    for (NSInteger i = 0; i < lines.count; i++) {
        if ([lines[i] containsString:@"PID"] && [lines[i] containsString:@"POWER"]) {
            headerCount++;
            if (headerCount == 2) { start = i + 1; break; }
        }
    }
    if (start < 0) return @[];

    NSMutableDictionary<NSString *, NSNumber *> *sum = [NSMutableDictionary dictionary];
    for (NSInteger i = start; i < lines.count; i++) {
        NSMutableArray<NSString *> *cols = [NSMutableArray array];
        for (NSString *s in [lines[i] componentsSeparatedByCharactersInSet:
                             NSCharacterSet.whitespaceCharacterSet])
            if (s.length) [cols addObject:s];
        if (cols.count < 3) continue;
        if ([cols.firstObject isEqual:@"PID"]) break;   // ran past the 2nd frame
        pid_t pid = (pid_t)cols.firstObject.intValue;
        if (pid <= 0) continue;
        double power = cols.lastObject.doubleValue;
        NSString *group = groupForPid(pid);
        if (!group) group = cols[1];
        sum[group] = @(sum[group].doubleValue + power);
    }
    NSArray<NSString *> *keys = [sum keysSortedByValueUsingComparator:
        ^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSString *k in keys) {
        if (out.count >= topN) break;
        if (sum[k].doubleValue <= 0) continue;
        [out addObject:@{@"name": k, @"impact": sum[k]}];
    }
    return out;
}
