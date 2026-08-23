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

// Every scalar below is read out of JSON we do not control (Codex session logs, Claude
// transcripts, account APIs). An *absent* key is harmless — messaging nil returns 0 — but a
// literal JSON null decodes to NSNull, which answers no scalar selector and aborts the
// process. Read null the same way we read absent: as zero.
static double JSONDouble(id value) {
    return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 0;
}

static long long JSONInteger(id value) {
    return [value isKindOfClass:NSNumber.class] ? [value longLongValue] : 0;
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
    long long input = JSONInteger(last[@"input_tokens"]);
    long long cachedInput = JSONInteger(last[@"cached_input_tokens"]);
    long long output = JSONInteger(last[@"output_tokens"]);
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

    long long input = JSONInteger(usage[@"input_tokens"]);
    long long output = JSONInteger(usage[@"output_tokens"]);
    long long cacheCreate = JSONInteger(usage[@"cache_creation_input_tokens"]);
    long long cacheRead = JSONInteger(usage[@"cache_read_input_tokens"]);
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
        long long tokens = JSONInteger(e[@"tokens"]);
        long long fresh = JSONInteger(e[@"fresh"]);
        if (tokens > 0 || fresh > 0) {
            NSString *day = [dayFmt stringFromDate:date];
            NSDictionary *cur = days[day];
            days[day] = @{@"t": @([cur[@"t"] longLongValue] + tokens),
                          @"f": @([cur[@"f"] longLongValue] + fresh)};
        }
        // Fold every snapshot, not just the newest: the last one to carry a window is
        // often not the last one to arrive. See MergeCodexRateLimits.
        if (e[@"limits"]) {
            latestLimits = MergeCodexRateLimits(latestLimits, latestTs, e[@"limits"], ts);
            if (!latestTs || [ts compare:latestTs] == NSOrderedDescending) latestTs = ts;
        }
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithObject:days forKey:@"days"];
    if (latestLimits) { out[@"latestLimits"] = latestLimits; out[@"latestTs"] = latestTs; }
    return out;
}

// --- Codex rate-limit meters ---
// A snapshot's `primary`/`secondary`/`credits` are independent meters that appear and
// disappear separately, so they are merged and aged separately too. The stamp is ours,
// not OpenAI's; it rides inside the meter so it survives the state file round-trip.
static NSString *const kCodexObservedAtKey = @"_glancebarObservedAt";

static BOOL CodexWindowUsable(id meter) {
    return [meter isKindOfClass:NSDictionary.class] &&
           [((NSDictionary *)meter)[@"used_percent"] isKindOfClass:NSNumber.class];
}

static BOOL CodexCreditsUsable(id meter) {
    if (![meter isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *d = meter;
    return [d[@"has_credits"] isKindOfClass:NSNumber.class] || [d[@"unlimited"] isKindOfClass:NSNumber.class];
}

// When this meter was actually observed: its own stamp once carried forward, otherwise
// the snapshot it arrived in.
static NSString *CodexMeterObservedAt(NSDictionary *meter, NSString *snapshotTs) {
    NSString *stamp = [meter[kCodexObservedAtKey] isKindOfClass:NSString.class]
        ? meter[kCodexObservedAtKey] : nil;
    return stamp.length ? stamp : snapshotTs;
}

static NSDictionary *CodexStampedMeter(NSDictionary *meter, NSString *ts) {
    if (!meter || !ts.length || meter[kCodexObservedAtKey]) return meter;
    NSMutableDictionary *stamped = [meter mutableCopy];
    stamped[kCodexObservedAtKey] = ts;
    return stamped;
}

// One meter's winner: a usable reading always beats an absent one, and between two
// usable readings the later observation wins (Codex timestamps are ISO-8601 UTC, so
// they order lexicographically — the same assumption the rest of this file makes).
static NSDictionary *CodexBetterMeter(id kept, NSString *keptTs, id incoming, NSString *incomingTs,
                                      BOOL isCredits) {
    BOOL keptOK = isCredits ? CodexCreditsUsable(kept) : CodexWindowUsable(kept);
    BOOL incomingOK = isCredits ? CodexCreditsUsable(incoming) : CodexWindowUsable(incoming);
    if (!incomingOK) return keptOK ? CodexStampedMeter(kept, keptTs) : nil;
    if (!keptOK) return CodexStampedMeter(incoming, incomingTs);
    NSString *keptAt = CodexMeterObservedAt(kept, keptTs);
    NSString *incomingAt = CodexMeterObservedAt(incoming, incomingTs);
    BOOL incomingWins = !keptAt.length ||
        (incomingAt.length && [incomingAt compare:keptAt] != NSOrderedAscending);
    return incomingWins ? CodexStampedMeter(incoming, incomingTs) : CodexStampedMeter(kept, keptTs);
}

// When a snapshot's window pair was observed: the later of the two stamps it carries.
// Nil when the snapshot has no usable window at all.
static NSString *CodexWindowsObservedAt(NSDictionary *snapshot, NSString *snapshotTs) {
    NSString *best = nil;
    for (NSString *key in @[@"primary", @"secondary"]) {
        if (!CodexWindowUsable(snapshot[key])) continue;
        NSString *at = CodexMeterObservedAt(snapshot[key], snapshotTs);
        if (at.length && (!best || [at compare:best] == NSOrderedDescending)) best = at;
    }
    return best;
}

NSDictionary *MergeCodexRateLimits(NSDictionary *kept, NSString *keptTs,
                                   NSDictionary *incoming, NSString *incomingTs) {
    if (![kept isKindOfClass:NSDictionary.class]) kept = nil;
    if (![incoming isKindOfClass:NSDictionary.class]) incoming = nil;
    if (!kept && !incoming) return nil;
    // Scalars (limit_id, plan_type, rate_limit_reached_type) describe the snapshot as a
    // whole, so they come from whichever snapshot is newer.
    BOOL incomingIsNewer = !kept || !keptTs.length ||
        (incomingTs.length && [incomingTs compare:keptTs] != NSOrderedAscending);
    NSMutableDictionary *out = [(incoming && incomingIsNewer ? incoming : (kept ?: incoming)) mutableCopy];

    // The window pair moves together, from whichever snapshot last carried one. primary
    // and secondary describe ONE bucket at ONE instant: taking the newest of each
    // separately can pair a spent weekly window with an untouched weekly window from a
    // bucket the account was billed to days ago, which reads as "0% left" and
    // "100% left" side by side. Both true once; together, a lie.
    NSString *keptAt = CodexWindowsObservedAt(kept, keptTs);
    NSString *incomingAt = CodexWindowsObservedAt(incoming, incomingTs);
    BOOL takeIncoming = incomingAt.length &&
        (!keptAt.length || [incomingAt compare:keptAt] != NSOrderedAscending);
    NSDictionary *windows = takeIncoming ? incoming : (keptAt.length ? kept : nil);
    NSString *windowsTs = takeIncoming ? incomingTs : keptTs;
    for (NSString *key in @[@"primary", @"secondary"]) {
        NSDictionary *w = CodexWindowUsable(windows[key]) ? CodexStampedMeter(windows[key], windowsTs) : nil;
        if (w) out[key] = w;
        else [out removeObjectForKey:key];   // drop JSON null rather than store NSNull
    }
    // Credits are one account-level meter with no pairing to preserve, so the newest
    // usable reading simply wins.
    NSDictionary *credits = CodexBetterMeter(kept[@"credits"], keptTs, incoming[@"credits"], incomingTs, YES);
    if (credits) out[@"credits"] = credits;
    else [out removeObjectForKey:@"credits"];
    return out;
}

NSDictionary *CodexCreditsStatus(NSDictionary *rateLimits) {
    if (![rateLimits isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *credits = [rateLimits[@"credits"] isKindOfClass:NSDictionary.class]
        ? rateLimits[@"credits"] : nil;
    if (!CodexCreditsUsable(credits)) return nil;
    BOOL unlimited = [credits[@"unlimited"] boolValue];
    BOOL has = [credits[@"has_credits"] boolValue];
    NSString *balance = [credits[@"balance"] isKindOfClass:NSString.class] ? credits[@"balance"]
        : [credits[@"balance"] isKindOfClass:NSNumber.class] ? [credits[@"balance"] stringValue] : nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"unlimited"] = @(unlimited);
    out[@"exhausted"] = @(!unlimited && !has);
    if (balance.length) out[@"balance"] = balance;
    out[@"description"] = unlimited ? @"Unlimited credits"
        : has ? (balance.length ? [NSString stringWithFormat:@"Credits available (balance %@)", balance]
                                : @"Credits available")
              : (balance.length ? [NSString stringWithFormat:@"No credits (balance %@)", balance]
                                : @"No credits");
    NSString *observed = CodexMeterObservedAt(credits, nil);
    if (observed.length) out[@"observedAt"] = observed;
    return out;
}

NSDictionary *PickLimitWindow(NSDictionary *rateLimits, double nowEpoch) {
    if (![rateLimits isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *best = nil;
    double bestRemaining = 2;
    for (NSString *key in @[@"primary", @"secondary"]) {
        NSDictionary *w = [rateLimits[key] isKindOfClass:NSDictionary.class] ? rateLimits[key] : nil;
        if (![w[@"used_percent"] isKindOfClass:NSNumber.class]) continue;
        double resets = JSONDouble(w[@"resets_at"]);
        if (resets > 0 && resets <= nowEpoch) continue;   // window already reset; gauge obsolete
        double remaining = 1.0 - [w[@"used_percent"] doubleValue] / 100.0;
        remaining = remaining < 0 ? 0 : remaining > 1 ? 1 : remaining;
        if (remaining >= bestRemaining) continue;
        bestRemaining = remaining;
        long mins = (long)JSONInteger(w[@"window_minutes"]);
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"remainingFraction"] = @(remaining);
        d[@"window"] = mins == 10080 ? @"weekly" : mins == 300 ? @"5-hour"
                     : mins > 0 ? [NSString stringWithFormat:@"%ld-minute", mins] : @"usage";
        if (resets > 0) d[@"resetsAt"] = @(resets);
        if ([rateLimits[@"plan_type"] isKindOfClass:NSString.class]) d[@"plan"] = rateLimits[@"plan_type"];
        NSString *observed = CodexMeterObservedAt(w, nil);
        if (observed.length) d[@"observedAt"] = observed;   // a carried-forward window is older than its snapshot
        best = d;
    }
    return best;
}

NSDictionary *PickClaudeLimitWindow(NSDictionary *usage, double nowEpoch) {
    // Use the exact same validation and provider semantics as the detailed meters so
    // an unknown or reset-less placeholder cannot disagree with (or drive) the headline.
    NSArray<NSDictionary *> *windows = ClaudeLimitWindows(usage, nowEpoch);
    NSDictionary *best = nil;
    double bestRemaining = 2;
    for (NSDictionary *window in windows) {
        double remaining = [window[@"remainingFraction"] doubleValue];
        if (remaining >= bestRemaining) continue;
        bestRemaining = remaining;
        best = window;
    }
    return best;
}

NSArray<NSDictionary *> *CodexLimitWindows(NSDictionary *rateLimits, double nowEpoch) {
    if (![rateLimits isKindOfClass:NSDictionary.class]) return @[];
    NSString *plan = [rateLimits[@"plan_type"] isKindOfClass:NSString.class] ? rateLimits[@"plan_type"] : nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *key in @[@"primary", @"secondary"]) {   // 5h then weekly, as the source presents them
        NSDictionary *w = [rateLimits[key] isKindOfClass:NSDictionary.class] ? rateLimits[key] : nil;
        if (![w[@"used_percent"] isKindOfClass:NSNumber.class]) continue;
        double resets = JSONDouble(w[@"resets_at"]);
        if (resets > 0 && resets <= nowEpoch) continue;   // window already reset; gauge obsolete
        double remaining = 1.0 - [w[@"used_percent"] doubleValue] / 100.0;
        remaining = remaining < 0 ? 0 : remaining > 1 ? 1 : remaining;
        long mins = (long)JSONInteger(w[@"window_minutes"]);
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"window"] = mins == 10080 ? @"weekly" : mins == 300 ? @"5-hour"
                     : mins > 0 ? [NSString stringWithFormat:@"%ld-minute", mins] : @"usage";
        d[@"remainingFraction"] = @(remaining);
        if (resets > 0) d[@"resetsAt"] = @(resets);
        if (plan) d[@"plan"] = plan;
        NSString *observed = CodexMeterObservedAt(w, nil);
        if (observed.length) d[@"observedAt"] = observed;
        [out addObject:d];
    }
    return out;
}

static NSArray<NSDictionary *> *ClaudeWindowsFiltered(NSDictionary *usage, double nowEpoch,
                                                      BOOL elapsedOnly);

NSArray<NSDictionary *> *ClaudeLimitWindows(NSDictionary *usage, double nowEpoch) {
    return ClaudeWindowsFiltered(usage, nowEpoch, NO);
}

NSArray<NSDictionary *> *ClaudeStaleLimitWindows(NSDictionary *usage, double nowEpoch) {
    return ClaudeWindowsFiltered(usage, nowEpoch, YES);
}

static NSArray<NSDictionary *> *ClaudeWindowsFiltered(NSDictionary *usage, double nowEpoch,
                                                      BOOL elapsedOnly) {
    if (![usage isKindOfClass:NSDictionary.class]) return @[];
    // Fixed reading order so the dual meter always renders 5-hour before weekly,
    // independent of dictionary iteration order. Only known windows are surfaced
    // (extra_usage is a credit budget, not a rate window, and is never included).
    // weekly Sonnet (seven_day_sonnet) is intentionally absent from this order, so it is
    // never surfaced in the dual meter regardless of what the API reports for it.
    NSArray *order = @[@"five_hour", @"seven_day", @"seven_day_opus"];
    NSDictionary *labels = @{@"five_hour": @"5-hour", @"seven_day": @"weekly",
                             @"seven_day_opus": @"weekly Opus"};
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *key in order) {
        NSDictionary *w = [usage[key] isKindOfClass:NSDictionary.class] ? usage[key] : nil;
        if (![w[@"utilization"] isKindOfClass:NSNumber.class]) continue;
        // Anthropic's OAuth usage contract reports percentage utilization, including
        // values below 1.0. Never infer a fraction from the value's magnitude.
        double used = [w[@"utilization"] doubleValue] / 100.0;
        double resets = 0;
        id resetsAt = w[@"resets_at"];
        if ([resetsAt isKindOfClass:NSNumber.class]) resets = [resetsAt doubleValue];
        else if ([resetsAt isKindOfClass:NSString.class]) resets = DateFromISO8601(resetsAt).timeIntervalSince1970;
        // Live: require a still-future reset (drops elapsed windows and reset-less
        // placeholders). Stale: require a real elapsed reset (same placeholder exclusion).
        if (resets <= 0) continue;
        if (elapsedOnly) {
            if (resets > nowEpoch) continue;
        } else if (resets <= nowEpoch) {
            continue;
        }
        double remaining = 1.0 - used;
        remaining = remaining < 0 ? 0 : remaining > 1 ? 1 : remaining;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"window"] = labels[key];
        d[@"remainingFraction"] = @(remaining);
        d[@"resetsAt"] = @(resets);
        [out addObject:d];
    }
    return out;
}

NSDictionary *PickClaudeStaleLimitWindow(NSDictionary *usage, double nowEpoch) {
    NSArray<NSDictionary *> *windows = ClaudeStaleLimitWindows(usage, nowEpoch);
    NSDictionary *best = nil;
    double bestResets = -1;
    double bestRemaining = 2;
    for (NSDictionary *window in windows) {
        double resets = [window[@"resetsAt"] doubleValue];
        double remaining = [window[@"remainingFraction"] doubleValue];
        if (resets > bestResets || (resets == bestResets && remaining < bestRemaining)) {
            bestResets = resets;
            bestRemaining = remaining;
            best = window;
        }
    }
    return best;
}

static NSString *DatedLimitResetReason(NSString *prefix, NSString *fetchedAtISO) {
    NSDate *snapshot = fetchedAtISO.length ? DateFromISO8601(fetchedAtISO) : nil;
    if (!snapshot) return prefix;
    NSDateFormatter *fmt = [NSDateFormatter new];
    [fmt setLocalizedDateFormatFromTemplate:@"d MMM"];
    return [NSString stringWithFormat:@"%@ (%@)", prefix, [fmt stringFromDate:snapshot]];
}

NSString *ClaudeLimitStatusReason(NSDictionary *usage, NSString *fetchedAtISO, double nowEpoch) {
    if (ClaudeLimitWindows(usage, nowEpoch).count) return nil;
    if (ClaudeStaleLimitWindows(usage, nowEpoch).count)
        return DatedLimitResetReason(@"Limit windows reset since last Claude refresh", fetchedAtISO);
    return @"Account response has no current limit window";
}

static double CursorEpochSeconds(id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        double n = [value doubleValue];
        // Dashboard timestamps are unix ms; treat large values as ms.
        return n > 1e12 ? n / 1000.0 : n;
    }
    if ([value isKindOfClass:NSString.class]) {
        NSString *s = (NSString *)value;
        if (!s.length) return 0;
        NSScanner *scanner = [NSScanner scannerWithString:s];
        double n = 0;
        if ([scanner scanDouble:&n] && scanner.isAtEnd) return n > 1e12 ? n / 1000.0 : n;
        NSDate *date = DateFromISO8601(s);
        return date ? date.timeIntervalSince1970 : 0;
    }
    return 0;
}

static NSDictionary *CursorPlanWindowFiltered(NSDictionary *usage, double nowEpoch, BOOL elapsedOnly) {
    NSDictionary *plan = [usage[@"planUsage"] isKindOfClass:NSDictionary.class] ? usage[@"planUsage"] : nil;
    if (!plan) return nil;
    double resets = CursorEpochSeconds(usage[@"billingCycleEnd"]);
    if (elapsedOnly) {
        if (!(resets > 0 && resets <= nowEpoch)) return nil;
    } else if (resets > 0 && resets <= nowEpoch) {
        return nil;
    }

    double remainingFrac = -1;
    NSNumber *remaining = [plan[@"remaining"] isKindOfClass:NSNumber.class] ? plan[@"remaining"] : nil;
    NSNumber *limit = [plan[@"limit"] isKindOfClass:NSNumber.class] ? plan[@"limit"] : nil;
    if (remaining && limit && limit.doubleValue > 0)
        remainingFrac = remaining.doubleValue / limit.doubleValue;
    else if ([plan[@"totalPercentUsed"] isKindOfClass:NSNumber.class])
        remainingFrac = 1.0 - [plan[@"totalPercentUsed"] doubleValue] / 100.0;
    else if ([plan[@"includedSpend"] isKindOfClass:NSNumber.class] && limit && limit.doubleValue > 0)
        remainingFrac = 1.0 - [plan[@"includedSpend"] doubleValue] / limit.doubleValue;
    if (remainingFrac < 0) return nil;
    remainingFrac = remainingFrac < 0 ? 0 : remainingFrac > 1 ? 1 : remainingFrac;

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"window"] = @"billing period";
    d[@"remainingFraction"] = @(remainingFrac);
    if (resets > 0) d[@"resetsAt"] = @(resets);
    return d;
}

static NSDictionary *CursorPlanWindow(NSDictionary *usage, double nowEpoch) {
    return CursorPlanWindowFiltered(usage, nowEpoch, NO);
}

static NSArray<NSDictionary *> *CursorAuthWindows(NSDictionary *usage, double nowEpoch) {
    // Prefer the gpt-4 included bucket (what community status bars surface); otherwise
    // take every model with a positive maxRequestUsage, most-constrained first for Pick*.
    NSMutableArray *out = [NSMutableArray array];
    NSArray *preferred = @[@"gpt-4", @"gpt-4o", @"claude-4-opus", @"claude-4-sonnet"];
    NSMutableSet *seen = [NSMutableSet set];
    void (^addBucket)(NSString *) = ^(NSString *key) {
        if (!key.length || [seen containsObject:key]) return;
        NSDictionary *bucket = [usage[key] isKindOfClass:NSDictionary.class] ? usage[key] : nil;
        if (![bucket[@"numRequests"] isKindOfClass:NSNumber.class] ||
            ![bucket[@"maxRequestUsage"] isKindOfClass:NSNumber.class]) return;
        double max = [bucket[@"maxRequestUsage"] doubleValue];
        if (max <= 0) return;
        double used = [bucket[@"numRequests"] doubleValue];
        double remaining = 1.0 - used / max;
        remaining = remaining < 0 ? 0 : remaining > 1 ? 1 : remaining;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"window"] = key;
        d[@"remainingFraction"] = @(remaining);
        double resets = CursorEpochSeconds(usage[@"startOfMonth"]);
        // startOfMonth is the cycle start, not the reset; only surface it when it is still
        // in the future (unusual) — otherwise leave reset blank rather than lying.
        if (resets > nowEpoch) d[@"resetsAt"] = @(resets);
        [seen addObject:key];
        [out addObject:d];
    };
    for (NSString *key in preferred) addBucket(key);
    if (!out.count) {
        for (NSString *key in usage) {
            if (![usage[key] isKindOfClass:NSDictionary.class]) continue;
            addBucket(key);
        }
    }
    return out;
}

NSArray<NSDictionary *> *CursorLimitWindows(NSDictionary *usage, double nowEpoch) {
    if (![usage isKindOfClass:NSDictionary.class]) return @[];
    NSDictionary *plan = CursorPlanWindow(usage, nowEpoch);
    if (plan) return @[plan];
    return CursorAuthWindows(usage, nowEpoch);
}

NSDictionary *PickCursorLimitWindow(NSDictionary *usage, double nowEpoch) {
    NSArray<NSDictionary *> *windows = CursorLimitWindows(usage, nowEpoch);
    NSDictionary *best = nil;
    double bestRemaining = 2;
    for (NSDictionary *window in windows) {
        double remaining = [window[@"remainingFraction"] doubleValue];
        if (remaining >= bestRemaining) continue;
        bestRemaining = remaining;
        best = window;
    }
    return best;
}

NSArray<NSDictionary *> *CursorStaleLimitWindows(NSDictionary *usage, double nowEpoch) {
    if (![usage isKindOfClass:NSDictionary.class]) return @[];
    // Plan billing cycles are the Cursor windows that actually expire. Auth buckets have
    // no reliable past reset marker, so they are not inventing a stale gauge here.
    NSDictionary *plan = CursorPlanWindowFiltered(usage, nowEpoch, YES);
    return plan ? @[plan] : @[];
}

NSDictionary *PickCursorStaleLimitWindow(NSDictionary *usage, double nowEpoch) {
    NSArray<NSDictionary *> *windows = CursorStaleLimitWindows(usage, nowEpoch);
    NSDictionary *best = nil;
    double bestResets = -1;
    double bestRemaining = 2;
    for (NSDictionary *window in windows) {
        double resets = [window[@"resetsAt"] doubleValue];
        double remaining = [window[@"remainingFraction"] doubleValue];
        if (resets > bestResets || (resets == bestResets && remaining < bestRemaining)) {
            bestResets = resets;
            bestRemaining = remaining;
            best = window;
        }
    }
    return best;
}

NSString *CursorLimitStatusReason(NSDictionary *usage, NSString *fetchedAtISO, double nowEpoch) {
    if (CursorLimitWindows(usage, nowEpoch).count) return nil;
    if (CursorStaleLimitWindows(usage, nowEpoch).count)
        return DatedLimitResetReason(@"Limit windows reset since last Cursor refresh", fetchedAtISO);
    return @"Account response has no current limit window";
}

NSDictionary *ClaudeExtraUsageStatus(NSDictionary *usage) {
    if (![usage isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *extra = [usage[@"extra_usage"] isKindOfClass:NSDictionary.class] ? usage[@"extra_usage"] : nil;
    if (!extra || ![extra[@"monthly_limit"] isKindOfClass:NSNumber.class]) return nil;
    id enabled = extra[@"is_enabled"];
    if ([enabled isKindOfClass:NSNumber.class] && ![enabled boolValue]) return nil;
    // The API sends null for these counters until extra usage is consumed; read them as zero.
    double utilization = JSONDouble(extra[@"utilization"]);
    double usedCredits = JSONDouble(extra[@"used_credits"]);
    double monthlyLimit = JSONDouble(extra[@"monthly_limit"]);
    NSString *currency = [extra[@"currency"] isKindOfClass:NSString.class] ? extra[@"currency"] : @"";
    BOOL overage = utilization >= 100.0 || (monthlyLimit > 0 && usedCredits >= monthlyLimit);
    NSString *description = [NSString stringWithFormat:@"%.0f of %@ %@ (%.0f%%)",
                             usedCredits, extra[@"monthly_limit"], currency, utilization];
    return @{@"description": description,
             @"statusReason": overage ? @"Overage billing active" : @"Extra usage active",
             @"overageActive": @(overage)};
}

// --- AI status line ---

// "in 42m" / "in 3h 20m" / "in 4d" — coarse enough to stay true between refreshes,
// specific enough to plan the next hour around.
static NSString *ResetCountdown(NSTimeInterval seconds) {
    if (seconds < 60) return @"any moment";
    if (seconds < 3600) return [NSString stringWithFormat:@"in %dm", (int)(seconds / 60)];
    if (seconds < 86400) {
        int hours = (int)(seconds / 3600), minutes = (int)((seconds - hours * 3600) / 60);
        return minutes ? [NSString stringWithFormat:@"in %dh %dm", hours, minutes]
                       : [NSString stringWithFormat:@"in %dh", hours];
    }
    return [NSString stringWithFormat:@"in %dd", (int)(seconds / 86400)];
}

NSString *ResetClockText(NSDate *resetAt, NSDate *now) {
    if (!resetAt) return nil;
    NSDate *reference = now ?: NSDate.date;
    NSCalendar *cal = NSCalendar.currentCalendar;
    // Calendar days, not elapsed hours: "Wed" is unambiguous up to a week out, and a
    // reset 20 hours away can still land the day after tomorrow.
    NSInteger days = [cal components:NSCalendarUnitDay
                            fromDate:[cal startOfDayForDate:reference]
                              toDate:[cal startOfDayForDate:resetAt]
                             options:0].day;
    NSDateFormatter *fmt = [NSDateFormatter new];
    if (days <= 0 || days == 1) {
        fmt.dateStyle = NSDateFormatterNoStyle;
        fmt.timeStyle = NSDateFormatterShortStyle;
        NSString *time = [fmt stringFromDate:resetAt];
        return days == 1 ? [@"tomorrow " stringByAppendingString:time] : time;
    }
    [fmt setLocalizedDateFormatFromTemplate:days <= 6 ? @"EEE jmm" : @"d MMM jmm"];
    return [fmt stringFromDate:resetAt];
}

NSString *ResetPhrase(NSDate *resetAt, NSDate *now) {
    if (!resetAt) return nil;
    NSDate *reference = now ?: NSDate.date;
    NSTimeInterval remaining = [resetAt timeIntervalSinceDate:reference];
    // Only a cached window whose reset has already come and gone lands here: the figure
    // above the line is last-known, and the refresh that would clear it hasn't landed.
    if (remaining <= 0) return @"Reset has passed";
    return [NSString stringWithFormat:@"Resets %@ · %@",
            ResetClockText(resetAt, reference), ResetCountdown(remaining)];
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
        double resets = JSONDouble(w[@"resets_at"]);
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

NSNumber *ParseSleepDisabled(NSString *pmsetOutput) {
    for (NSString *line in [pmsetOutput componentsSeparatedByString:@"\n"]) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSString *s in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
            if (s.length) [parts addObject:s];
        if (parts.count >= 2 && [parts[0] isEqualToString:@"SleepDisabled"])
            return @(parts[1].integerValue != 0);
    }
    return nil;
}

#pragma mark - Adaptive bar width

const double kBarShrinkMarginPt = 4;
const double kBarExpandMarginPt = 24;
const int    kBarExpandTicks    = 2;
const double kBarExpandMinIntervalSec = 10;

BarTierState ChooseBarTier(BarTierState prev, double gapPt,
                           const double widths[3], BOOL evicted, double nowEpoch) {
    // Every non-qualifying path resets the streak AND its clock, so the next
    // qualifying decision starts a fresh window and counts immediately.
    BarTierState s = { .tier = MIN(MAX(prev.tier, BarTierFull), BarTierGlyph),
                       .expandStreak = 0, .lastCountedAt = 0 };
    if (evicted) { s.tier = BarTierGlyph; return s; }
    if (gapPt < 0) return s;
    if (widths[s.tier] + kBarShrinkMarginPt > gapPt) {
        // Widest tier that fits with margin; the glyph is the floor — Glancebar
        // never voluntarily hides, even if macOS may still evict the glyph.
        while (s.tier < BarTierGlyph && widths[s.tier] + kBarShrinkMarginPt > gapPt)
            s.tier++;
        return s;
    }
    if (s.tier > BarTierFull && widths[s.tier - 1] + kBarExpandMarginPt <= gapPt) {
        if (nowEpoch - prev.lastCountedAt >= kBarExpandMinIntervalSec) {
            s.expandStreak = prev.expandStreak + 1;
            s.lastCountedAt = nowEpoch;
            if (s.expandStreak >= kBarExpandTicks) { s.tier--; s.expandStreak = 0; }
        } else {
            // Still qualifying, just too soon to count again: hold the streak and
            // its clock rather than resetting (a burst must not punish us either).
            s.expandStreak = prev.expandStreak;
            s.lastCountedAt = prev.lastCountedAt;
        }
    }
    return s;
}
