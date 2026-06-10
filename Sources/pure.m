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

static NSString *CommandFromColumns(NSArray<NSString *> *cols) {
    if (cols.count < 3) return @"";
    NSRange r = NSMakeRange(1, cols.count - 2);
    return [[cols subarrayWithRange:r] componentsJoinedByString:@" "];
}

NSArray<NSDictionary *> *ParseHogs(NSString *topOutput, int topN,
                                   NSString *(^groupForPid)(pid_t)) {
    if (topN <= 0) return @[];
    NSArray<NSString *> *lines = [topOutput componentsSeparatedByString:@"\n"];
    NSUInteger headerCount = 0, start = NSNotFound;
    for (NSUInteger i = 0; i < lines.count; i++) {
        if ([lines[i] containsString:@"PID"] && [lines[i] containsString:@"POWER"]) {
            headerCount++;
            if (headerCount == 2) { start = i + 1; break; }
        }
    }
    if (start == NSNotFound) return @[];

    NSMutableDictionary<NSString *, NSNumber *> *sum = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *commands = [NSMutableDictionary dictionary];
    for (NSUInteger i = start; i < lines.count; i++) {
        NSMutableArray<NSString *> *cols = [NSMutableArray array];
        for (NSString *s in [lines[i] componentsSeparatedByCharactersInSet:
                             NSCharacterSet.whitespaceCharacterSet])
            if (s.length) [cols addObject:s];
        if (cols.count < 3) continue;
        if ([cols.firstObject isEqual:@"PID"]) break;   // ran past the 2nd frame
        pid_t pid = (pid_t)cols.firstObject.intValue;
        if (pid <= 0) continue;
        double power = cols.lastObject.doubleValue;
        NSString *command = CommandFromColumns(cols);
        NSString *group = groupForPid(pid);
        if (!group.length) group = command;
        if (!group.length) continue;
        sum[group] = @(sum[group].doubleValue + power);
        if (command.length) {
            if (!commands[group]) commands[group] = [NSMutableSet set];
            [commands[group] addObject:command];
        }
    }
    NSArray<NSString *> *keys = [sum keysSortedByValueUsingComparator:
        ^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
    double totalImpact = 0;
    for (NSString *k in keys) if (sum[k].doubleValue > 0) totalImpact += sum[k].doubleValue;
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSString *k in keys) {
        if (out.count >= (NSUInteger)topN) break;
        if (sum[k].doubleValue <= 0) continue;
        NSArray *commandList = [[commands[k] allObjects] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        [out addObject:@{@"name": k, @"impact": sum[k], @"totalImpact": @(totalImpact),
                         @"commands": commandList ? commandList : @[]}];
    }
    return out;
}

NSDictionary *ParseTokenCountLine(NSString *line) {
    if (![line containsString:@"\"token_count\""]) return nil;   // cheap pre-filter
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *payload = [obj[@"payload"] isKindOfClass:NSDictionary.class] ? obj[@"payload"] : nil;
    if (![payload[@"type"] isKindOfClass:NSString.class] || ![payload[@"type"] isEqualToString:@"token_count"]) return nil;
    NSString *ts = [obj[@"timestamp"] isKindOfClass:NSString.class] ? obj[@"timestamp"] : nil;
    if (!ts.length) return nil;

    NSDictionary *info = [payload[@"info"] isKindOfClass:NSDictionary.class] ? payload[@"info"] : nil;
    NSDictionary *last = [info[@"last_token_usage"] isKindOfClass:NSDictionary.class] ? info[@"last_token_usage"] : nil;
    NSNumber *total = [last[@"total_tokens"] isKindOfClass:NSNumber.class] ? last[@"total_tokens"] : nil;
    NSDictionary *limits = [payload[@"rate_limits"] isKindOfClass:NSDictionary.class] ? payload[@"rate_limits"] : nil;
    if (!total && !limits) return nil;

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"ts"] = ts;
    out[@"tokens"] = total ?: @0;
    if (limits) out[@"limits"] = limits;
    return out;
}

static NSDate *DateFromISO8601(NSString *s) {
    static NSISO8601DateFormatter *plain, *fractional;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        plain = [NSISO8601DateFormatter new];
        fractional = [NSISO8601DateFormatter new];
        fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return [fractional dateFromString:s] ?: [plain dateFromString:s];
}

NSDictionary *AccumulateTokenEvents(NSDictionary<NSString *, NSNumber *> *existingDays,
                                    NSArray<NSDictionary *> *events, NSTimeZone *tz) {
    NSMutableDictionary *days = existingDays ? [existingDays mutableCopy] : [NSMutableDictionary dictionary];
    NSDictionary *latestLimits = nil;
    NSString *latestTs = nil;
    NSDateFormatter *dayFmt = [NSDateFormatter new];
    dayFmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dayFmt.dateFormat = @"yyyy-MM-dd";
    dayFmt.timeZone = tz ?: NSTimeZone.localTimeZone;
    for (NSDictionary *e in events) {
        NSString *ts = [e[@"ts"] isKindOfClass:NSString.class] ? e[@"ts"] : nil;
        NSDate *date = ts ? DateFromISO8601(ts) : nil;
        if (!date) continue;
        long long tokens = [e[@"tokens"] longLongValue];
        if (tokens > 0) {
            NSString *day = [dayFmt stringFromDate:date];
            days[day] = @([days[day] longLongValue] + tokens);
        }
        if (e[@"limits"] && (!latestTs || [ts compare:latestTs] == NSOrderedDescending)) {
            latestTs = ts;
            latestLimits = e[@"limits"];
        }
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithObject:days forKey:@"days"];
    if (latestLimits) { out[@"latestLimits"] = latestLimits; out[@"latestTs"] = latestTs; }
    return out;
}

NSDictionary *PickLimitWindow(NSDictionary *rateLimits, double nowEpoch) {
    if (![rateLimits isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *best = nil;
    double bestRemaining = 2;
    for (NSString *key in @[@"primary", @"secondary"]) {
        NSDictionary *w = [rateLimits[key] isKindOfClass:NSDictionary.class] ? rateLimits[key] : nil;
        if (![w[@"used_percent"] isKindOfClass:NSNumber.class]) continue;
        double resets = [w[@"resets_at"] doubleValue];
        if (resets > 0 && resets <= nowEpoch) continue;   // window already reset; gauge obsolete
        double remaining = 1.0 - [w[@"used_percent"] doubleValue] / 100.0;
        remaining = remaining < 0 ? 0 : remaining > 1 ? 1 : remaining;
        if (remaining >= bestRemaining) continue;
        bestRemaining = remaining;
        long mins = [w[@"window_minutes"] longValue];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"remainingFraction"] = @(remaining);
        d[@"window"] = mins == 10080 ? @"weekly" : mins == 300 ? @"5-hour"
                     : mins > 0 ? [NSString stringWithFormat:@"%ld-minute", mins] : @"usage";
        if (resets > 0) d[@"resetsAt"] = @(resets);
        if ([rateLimits[@"plan_type"] isKindOfClass:NSString.class]) d[@"plan"] = rateLimits[@"plan_type"];
        best = d;
    }
    return best;
}

static NSString *Trimmed(NSString *s) {
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *FallbackProcessName(NSString *command) {
    NSString *trimmed = Trimmed(command);
    NSString *last = trimmed.lastPathComponent;
    return last.length ? last : trimmed;
}

static NSArray<NSDictionary *> *RowsSortedBy(NSDictionary<NSString *, NSMutableDictionary *> *groups,
                                             NSString *key, int topN) {
    NSArray<NSString *> *names = [groups keysSortedByValueUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[key] compare:a[key]];
        }];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NSString *name in names) {
        if (rows.count >= (NSUInteger)topN) break;
        NSMutableDictionary *g = groups[name];
        double cpu = [g[@"cpu"] doubleValue];
        unsigned long long bytes = [g[@"bytes"] unsignedLongLongValue];
        if (([key isEqualToString:@"cpu"] && cpu <= 0.05) ||
            ([key isEqualToString:@"bytes"] && bytes == 0)) continue;
        NSArray *commands = [[g[@"commands"] allObjects] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        [rows addObject:@{@"name": name, @"cpu": @(cpu), @"bytes": @(bytes),
                          @"commands": commands ? commands : @[]}];
    }
    return rows;
}

NSDictionary<NSString *, NSArray<NSDictionary *> *> *ParseProcessStats(NSString *psOutput, int topN,
                                                                        NSString *(^groupForPid)(pid_t),
                                                                        unsigned long long (^bytesForPid)(pid_t)) {
    if (topN <= 0) return @{@"cpu": @[], @"memory": @[]};
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    for (NSString *line in [psOutput componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = Trimmed(line);
        if (!trimmed.length) continue;
        NSArray<NSString *> *cols = [trimmed componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSString *s in cols) if (s.length) [parts addObject:s];
        if (parts.count < 4) continue;

        pid_t pid = (pid_t)parts[0].intValue;
        if (pid <= 0) continue;
        double cpu = parts[1].doubleValue;
        unsigned long long bytes = bytesForPid ? bytesForPid(pid) : 0;
        if (bytes == 0) bytes = (unsigned long long)parts[2].longLongValue * 1024ULL;
        NSString *command = [[parts subarrayWithRange:NSMakeRange(3, parts.count - 3)] componentsJoinedByString:@" "];

        NSString *group = groupForPid(pid);
        if (!group.length) group = FallbackProcessName(command);
        if (!group.length) continue;

        NSMutableDictionary *g = groups[group];
        if (!g) {
            g = [@{@"cpu": @0.0, @"bytes": @(0ULL), @"commands": [NSMutableSet set]} mutableCopy];
            groups[group] = g;
        }
        g[@"cpu"] = @([g[@"cpu"] doubleValue] + cpu);
        g[@"bytes"] = @([g[@"bytes"] unsignedLongLongValue] + bytes);
        if (command.length) [g[@"commands"] addObject:FallbackProcessName(command)];
    }
    return @{@"cpu": RowsSortedBy(groups, @"cpu", topN),
             @"memory": RowsSortedBy(groups, @"bytes", topN)};
}
