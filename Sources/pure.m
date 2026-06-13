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
    // ~94% of total_tokens is cached context re-read every turn; fresh = what a human
    // would call "tokens used".
    long long input = [last[@"input_tokens"] longLongValue];
    long long cachedInput = [last[@"cached_input_tokens"] longLongValue];
    long long output = [last[@"output_tokens"] longLongValue];
    long long fresh = (input > cachedInput ? input - cachedInput : 0) + output;
    out[@"fresh"] = @(fresh);
    if (limits) out[@"limits"] = limits;
    return out;
}

NSDictionary *ParseClaudeUsageLine(NSString *line) {
    if (![line containsString:@"\"usage\""]) return nil;   // cheap pre-filter
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *message = [obj[@"message"] isKindOfClass:NSDictionary.class] ? obj[@"message"] : nil;
    NSDictionary *usage = [message[@"usage"] isKindOfClass:NSDictionary.class] ? message[@"usage"] : nil;
    NSString *ts = [obj[@"timestamp"] isKindOfClass:NSString.class] ? obj[@"timestamp"] : nil;
    if (!usage || !ts.length) return nil;

    long long input = [usage[@"input_tokens"] longLongValue];
    long long output = [usage[@"output_tokens"] longLongValue];
    long long cacheCreate = [usage[@"cache_creation_input_tokens"] longLongValue];
    long long cacheRead = [usage[@"cache_read_input_tokens"] longLongValue];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"ts"] = ts;
    out[@"fresh"] = @(input + output);                            // input is already non-cached
    out[@"tokens"] = @(input + output + cacheCreate + cacheRead);
    if ([message[@"id"] isKindOfClass:NSString.class]) out[@"id"] = message[@"id"];
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
    NSDate *date = [fractional dateFromString:s] ?: [plain dateFromString:s];
    if (date) return date;
    // Anthropic's usage endpoint emits microsecond fractions ("...00.730662+00:00"),
    // which NSISO8601DateFormatter rejects; strip the fraction and retry.
    NSRange dot = [s rangeOfString:@"."];
    if (dot.location == NSNotFound) return nil;
    NSUInteger end = dot.location + 1;
    while (end < s.length && isdigit([s characterAtIndex:end])) end++;
    NSString *stripped = [[s substringToIndex:dot.location] stringByAppendingString:[s substringFromIndex:end]];
    return [plain dateFromString:stripped];
}

NSDictionary *AccumulateTokenEvents(NSDictionary<NSString *, NSDictionary *> *existingDays,
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
        long long fresh = [e[@"fresh"] longLongValue];
        if (tokens > 0 || fresh > 0) {
            NSString *day = [dayFmt stringFromDate:date];
            NSDictionary *cur = days[day];
            days[day] = @{@"t": @([cur[@"t"] longLongValue] + tokens),
                          @"f": @([cur[@"f"] longLongValue] + fresh)};
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

NSDictionary *PickClaudeLimitWindow(NSDictionary *usage, double nowEpoch) {
    if (![usage isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *labels = @{@"five_hour": @"5-hour", @"seven_day": @"weekly",
                             @"seven_day_opus": @"weekly Opus", @"seven_day_sonnet": @"weekly Sonnet"};
    NSDictionary *best = nil;
    double bestRemaining = 2;
    for (NSString *key in usage) {
        if ([key isEqualToString:@"extra_usage"]) continue;   // a credit budget, not a rate window
        NSDictionary *w = [usage[key] isKindOfClass:NSDictionary.class] ? usage[key] : nil;
        id util = w[@"utilization"];
        if (![util isKindOfClass:NSNumber.class]) continue;
        double used = [util doubleValue];
        if (used > 1.0) used /= 100.0;          // tolerate percent or fraction
        double resets = 0;
        id resetsAt = w[@"resets_at"];
        if ([resetsAt isKindOfClass:NSNumber.class]) resets = [resetsAt doubleValue];
        else if ([resetsAt isKindOfClass:NSString.class]) resets = DateFromISO8601(resetsAt).timeIntervalSince1970;
        if (resets > 0 && resets <= nowEpoch) continue;   // window already reset; gauge obsolete
        double remaining = 1.0 - used;
        remaining = remaining < 0 ? 0 : remaining > 1 ? 1 : remaining;
        if (remaining >= bestRemaining) continue;
        bestRemaining = remaining;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"remainingFraction"] = @(remaining);
        d[@"window"] = labels[key] ?: key;
        if (resets > 0) d[@"resetsAt"] = @(resets);
        best = d;
    }
    return best;
}

NSDictionary *ClaudeExtraUsageStatus(NSDictionary *usage) {
    if (![usage isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *extra = [usage[@"extra_usage"] isKindOfClass:NSDictionary.class] ? usage[@"extra_usage"] : nil;
    if (!extra || ![extra[@"monthly_limit"] isKindOfClass:NSNumber.class]) return nil;
    id enabled = extra[@"is_enabled"];
    if ([enabled isKindOfClass:NSNumber.class] && ![enabled boolValue]) return nil;
    double utilization = [extra[@"utilization"] doubleValue];
    double usedCredits = [extra[@"used_credits"] doubleValue];
    double monthlyLimit = [extra[@"monthly_limit"] doubleValue];
    NSString *currency = [extra[@"currency"] isKindOfClass:NSString.class] ? extra[@"currency"] : @"";
    BOOL overage = utilization >= 100.0 || (monthlyLimit > 0 && usedCredits >= monthlyLimit);
    NSString *description = [NSString stringWithFormat:@"%.0f of %@ %@ (%.0f%%)",
                             usedCredits, extra[@"monthly_limit"], currency, utilization];
    return @{@"description": description,
             @"statusReason": overage ? @"Overage billing active" : @"Extra usage active",
             @"overageActive": @(overage)};
}

BOOL ShouldFetchClaudeAccount(BOOL useAccount, BOOL allowFetch, BOOL hasUsageJSON,
                              BOOL hasAccountStatus, double nowEpoch, double nextFetchEpoch) {
    if (!useAccount || !allowFetch) return NO;
    if (nowEpoch >= nextFetchEpoch) return YES;
    return !hasUsageJSON && !hasAccountStatus;
}

double RateLimitRetryDelay(double retryAfterSeconds) {
    double capped = retryAfterSeconds > 3600 ? 3600 : retryAfterSeconds;
    return capped < 900 ? 900 : capped;
}

BOOL ShouldDropCachedTokenForStatus(NSInteger statusCode) {
    return statusCode == 401 || statusCode == 403;
}

NSDictionary *ClaudeKeychainOutcome(BOOL itemFound, NSString *token,
                                    double expiresAtEpoch, double nowEpoch) {
    if (!itemFound || !token.length)
        return @{@"ok": @NO, @"retryDelay": @3600.0,
                 @"status": @"Keychain token unavailable; retrying later"};
    if (expiresAtEpoch > 0 && expiresAtEpoch <= nowEpoch)
        return @{@"ok": @NO, @"retryDelay": @300.0,
                 @"status": @"Claude Code token expired; waiting for it to refresh"};
    return @{@"ok": @YES, @"token": token, @"expiresAt": @(expiresAtEpoch)};
}

NSString *CodexLimitStatusReason(NSDictionary *rateLimits, NSString *limitsTs, double nowEpoch) {
    BOOL sawUsable = NO;
    for (NSString *key in @[@"primary", @"secondary"]) {
        NSDictionary *w = [rateLimits[key] isKindOfClass:NSDictionary.class] ? rateLimits[key] : nil;
        if (![w[@"used_percent"] isKindOfClass:NSNumber.class]) continue;
        sawUsable = YES;
        double resets = [w[@"resets_at"] doubleValue];
        if (!(resets > 0 && resets <= nowEpoch)) return nil;   // current window — gauge shows
    }
    if (!sawUsable) return @"Codex session logs do not carry limit status";
    NSDate *snapshot = limitsTs.length ? DateFromISO8601(limitsTs) : nil;
    if (!snapshot) return @"Limit windows reset since last Codex session";
    NSDateFormatter *fmt = [NSDateFormatter new];
    [fmt setLocalizedDateFormatFromTemplate:@"d MMM"];
    return [NSString stringWithFormat:@"Limit windows reset since last Codex session (%@)",
            [fmt stringFromDate:snapshot]];
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
