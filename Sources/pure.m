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
    NSString *model = [message[@"model"] isKindOfClass:NSString.class] ? message[@"model"] : nil;
    if (model.length) out[@"model"] = model;
    // Tool calls are content blocks on the same message. `usage.iterations[]` restates
    // the top-level counters for the same message and is deliberately never read.
    long long tools = 0;
    NSArray *content = [message[@"content"] isKindOfClass:NSArray.class] ? message[@"content"] : nil;
    for (id block in content)
        if ([block isKindOfClass:NSDictionary.class] && [block[@"type"] isEqual:@"tool_use"]) tools++;
    if (tools > 0) out[@"tools"] = @(tools);
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

NSDictionary *MergeDayCounts(NSDictionary *a, NSDictionary *b) {
    if (![a isKindOfClass:NSDictionary.class]) a = nil;
    if (![b isKindOfClass:NSDictionary.class]) b = nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"t", @"f", @"n", @"c"]) {
        long long sum = JSONInteger(a[key]) + JSONInteger(b[key]);
        // t and f are the day's identity and are always written; the newer counters
        // appear only once they are nonzero, so Codex records do not grow keys they never use.
        if (sum != 0 || [key isEqualToString:@"t"] || [key isEqualToString:@"f"]) out[key] = @(sum);
    }
    NSDictionary *ma = [a[@"m"] isKindOfClass:NSDictionary.class] ? a[@"m"] : nil;
    NSDictionary *mb = [b[@"m"] isKindOfClass:NSDictionary.class] ? b[@"m"] : nil;
    if (ma.count || mb.count) {
        NSMutableDictionary *models = [NSMutableDictionary dictionary];
        for (NSDictionary *source in @[ma ?: @{}, mb ?: @{}]) {
            for (NSString *model in source) {
                if (![model isKindOfClass:NSString.class] || !model.length) continue;
                long long value = JSONInteger(source[model]);
                if (value > 0) models[model] = @(JSONInteger(models[model]) + value);
            }
        }
        if (models.count) out[@"m"] = models;
    }
    return out;
}

NSDictionary *AccumulateTokenEvents(NSDictionary<NSString *, NSDictionary *> *existingDays,
                                    NSArray<NSDictionary *> *events, NSTimeZone *tz) {
    NSMutableDictionary *days = existingDays ? [existingDays mutableCopy] : [NSMutableDictionary dictionary];
    NSDictionary *latestLimits = nil, *newestLimits = nil, *buckets = nil;
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
        long long tools = JSONInteger(e[@"tools"]);
        if (tokens > 0 || fresh > 0 || tools > 0) {
            NSString *day = [dayFmt stringFromDate:date];
            // An amendment grows a message already counted: its tokens and tool calls
            // add, but it is not another message.
            BOOL amend = [e[@"amend"] isKindOfClass:NSNumber.class] && [e[@"amend"] boolValue];
            NSMutableDictionary *add = [@{@"t": @(tokens), @"f": @(fresh), @"n": @(amend ? 0 : 1)} mutableCopy];
            if (tools > 0) add[@"c"] = @(tools);
            NSString *model = [e[@"model"] isKindOfClass:NSString.class] ? e[@"model"] : nil;
            if (model.length && fresh > 0) add[@"m"] = @{model: @(fresh)};
            days[day] = MergeDayCounts(days[day], add);
        }
        // Fold every snapshot, not just the newest: the last one to carry a window is
        // often not the last one to arrive. See MergeCodexRateLimits — and keep each
        // limit_id apart, see FoldCodexSnapshotIntoBuckets.
        if ([e[@"limits"] isKindOfClass:NSDictionary.class]) {
            latestLimits = MergeCodexRateLimits(latestLimits, latestTs, e[@"limits"], ts);
            buckets = FoldCodexSnapshotIntoBuckets(buckets, e[@"limits"], ts);
            if (!latestTs || [ts compare:latestTs] == NSOrderedDescending) {
                latestTs = ts;
                newestLimits = e[@"limits"];
            }
        }
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithObject:days forKey:@"days"];
    if (latestLimits) {
        out[@"latestLimits"] = latestLimits;
        out[@"latestTs"] = latestTs;
        if (buckets) out[@"buckets"] = buckets;
        if (newestLimits) { out[@"newestLimits"] = newestLimits; out[@"newestTs"] = latestTs; }
    }
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
    if (!keptAt.length) return CodexStampedMeter(incoming, incomingTs);
    if (!incomingAt.length) return CodexStampedMeter(kept, keptTs);
    NSComparisonResult order = [incomingAt compare:keptAt];
    // Equal stamps are the same observation, so either reading is equally true — but the
    // caller folds records in whatever order a dictionary hands them over, and "either"
    // has to resolve the same way every run. Break ties toward the reading that claims
    // LESS left: never grant room that an equally-current reading says is spent.
    if (order == NSOrderedSame) {
        BOOL keptExhausted = [CodexCreditsStatus(@{@"credits": kept})[@"exhausted"] boolValue];
        return keptExhausted ? CodexStampedMeter(kept, keptTs) : CodexStampedMeter(incoming, incomingTs);
    }
    return order == NSOrderedDescending ? CodexStampedMeter(incoming, incomingTs)
                                        : CodexStampedMeter(kept, keptTs);
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

// The most-spent usable window in a snapshot, for resolving equal stamps.
static double CodexWindowsSpend(NSDictionary *snapshot) {
    double spend = -1;
    for (NSString *key in @[@"primary", @"secondary"]) {
        if (!CodexWindowUsable(snapshot[key])) continue;
        double used = JSONDouble(((NSDictionary *)snapshot[key])[@"used_percent"]);
        if (used > spend) spend = used;
    }
    return spend;
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
    BOOL takeIncoming;
    if (!incomingAt.length) takeIncoming = NO;
    else if (!keptAt.length) takeIncoming = YES;
    else {
        NSComparisonResult order = [incomingAt compare:keptAt];
        // Ties: the more-spent pair wins, so an arbitrary fold order can never be the
        // difference between reporting room and reporting none. See CodexBetterMeter.
        takeIncoming = order == NSOrderedSame ? CodexWindowsSpend(incoming) > CodexWindowsSpend(kept)
                                              : order == NSOrderedDescending;
    }
    NSDictionary *windows = takeIncoming ? incoming : (keptAt.length ? kept : nil);
    NSString *windowsTs = takeIncoming ? incomingTs : keptTs;
    // Carrying a window past a newer snapshot is only safe because it expires on its own
    // resets_at. One without a reset would never age out — it would sit there claiming a
    // stale percentage until the rollout file itself falls out of the 8-day inventory. A
    // window observed in the CURRENT snapshot is a live reading and needs no such proof.
    NSString *newestTs = !keptTs.length ? incomingTs
        : !incomingTs.length ? keptTs
        : ([incomingTs compare:keptTs] == NSOrderedDescending ? incomingTs : keptTs);
    BOOL carriedForward = windowsTs.length && newestTs.length &&
        [windowsTs compare:newestTs] == NSOrderedAscending;
    for (NSString *key in @[@"primary", @"secondary"]) {
        NSDictionary *w = CodexWindowUsable(windows[key]) ? windows[key] : nil;
        if (w && carriedForward && JSONDouble(w[@"resets_at"]) <= 0) w = nil;
        if (w) out[key] = CodexStampedMeter(w, windowsTs);
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
    // These payloads use JSON null freely (limit_name, individual_limit, primary…), and
    // CodexCreditsUsable passes when EITHER flag is a number — so -boolValue here would
    // meet NSNull and abort. Read both defensively, and say nothing rather than guess
    // when the flag that carries the meaning is the one that is missing.
    BOOL unlimited = [credits[@"unlimited"] isKindOfClass:NSNumber.class] &&
                     [credits[@"unlimited"] boolValue];
    BOOL hasKnown = [credits[@"has_credits"] isKindOfClass:NSNumber.class];
    BOOL has = hasKnown && [credits[@"has_credits"] boolValue];
    if (!unlimited && !hasKnown) return nil;
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

static double ClaudeResetEpoch(id resetsAt) {
    if ([resetsAt isKindOfClass:NSNumber.class]) return [resetsAt doubleValue];
    if ([resetsAt isKindOfClass:NSString.class]) return DateFromISO8601(resetsAt).timeIntervalSince1970;
    return 0;
}

// The display name of one `limits[]` entry, or nil for an entry with no readable kind.
static NSString *ClaudeLimitEntryLabel(NSDictionary *entry) {
    NSString *kind = [entry[@"kind"] isKindOfClass:NSString.class] ? entry[@"kind"] : nil;
    if (!kind.length) return nil;
    if ([kind isEqualToString:@"session"]) return @"5-hour";
    if ([kind isEqualToString:@"weekly_all"]) return @"weekly";
    if ([kind isEqualToString:@"weekly_scoped"]) {
        NSDictionary *scope = [entry[@"scope"] isKindOfClass:NSDictionary.class] ? entry[@"scope"] : nil;
        NSDictionary *model = [scope[@"model"] isKindOfClass:NSDictionary.class] ? scope[@"model"] : nil;
        NSString *name = [model[@"display_name"] isKindOfClass:NSString.class] ? model[@"display_name"] : nil;
        return name.length ? [@"weekly " stringByAppendingString:name] : @"weekly (model)";
    }
    // An unfamiliar kind still names itself ("monthly_all" → "monthly all") rather than
    // vanishing: the array is explicit about what each entry is.
    return [kind stringByReplacingOccurrencesOfString:@"_" withString:@" "];
}

// One reading → one window dict, or nil when it does not belong in this set.
static NSMutableDictionary *ClaudeWindowReading(NSString *label, double usedPercent, double resets,
                                                double nowEpoch, BOOL elapsedOnly, BOOL allowFresh) {
    // Anthropic reports a PERCENTAGE, including values below 1.0. Never infer a fraction
    // from the value's magnitude.
    if (resets <= 0) {
        // No reset instant. With nothing used this is a fresh window — 100% left, and
        // its clock starts on first use. Anything else reset-less is a placeholder.
        if (elapsedOnly || !allowFresh || usedPercent > 0) return nil;
        return [@{@"window": label, @"remainingFraction": @1.0, @"fresh": @YES} mutableCopy];
    }
    // Live: require a still-future reset. Stale: require a real elapsed reset.
    if (elapsedOnly ? resets > nowEpoch : resets <= nowEpoch) return nil;
    double remaining = 1.0 - usedPercent / 100.0;
    remaining = remaining < 0 ? 0 : remaining > 1 ? 1 : remaining;
    return [@{@"window": label, @"remainingFraction": @(remaining), @"resetsAt": @(resets)} mutableCopy];
}

static NSArray<NSDictionary *> *ClaudeWindowsFiltered(NSDictionary *usage, double nowEpoch,
                                                      BOOL elapsedOnly) {
    if (![usage isKindOfClass:NSDictionary.class]) return @[];
    // Readings: @{label, used (percent), resets (epoch or 0), kind?, active?}.
    NSMutableArray<NSDictionary *> *readings = [NSMutableArray array];
    // The `limits` array is authoritative whenever it is present and readable: it is the
    // only place the model-scoped weekly is named, and the legacy dicts mirror it.
    NSArray *limits = [usage[@"limits"] isKindOfClass:NSArray.class] ? usage[@"limits"] : nil;
    for (id entry in limits) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if (![entry[@"percent"] isKindOfClass:NSNumber.class]) continue;
        NSString *label = ClaudeLimitEntryLabel(entry);
        if (!label) continue;
        NSMutableDictionary *r = [@{@"label": label, @"used": entry[@"percent"],
                                    @"resets": @(ClaudeResetEpoch(entry[@"resets_at"]))} mutableCopy];
        r[@"kind"] = entry[@"kind"];
        if ([entry[@"is_active"] isKindOfClass:NSNumber.class]) r[@"active"] = entry[@"is_active"];
        [readings addObject:r];
    }
    if (!readings.count) {
        // Legacy shape. Fixed reading order so the dual meter always renders 5-hour
        // before weekly, independent of dictionary iteration order. Only known windows
        // are surfaced (extra_usage is a credit budget, not a rate window, and is never
        // included); weekly Sonnet (seven_day_sonnet) is intentionally absent.
        NSArray *order = @[@"five_hour", @"seven_day", @"seven_day_opus"];
        NSDictionary *labels = @{@"five_hour": @"5-hour", @"seven_day": @"weekly",
                                 @"seven_day_opus": @"weekly Opus"};
        for (NSString *key in order) {
            NSDictionary *w = [usage[key] isKindOfClass:NSDictionary.class] ? usage[key] : nil;
            if (![w[@"utilization"] isKindOfClass:NSNumber.class]) continue;
            [readings addObject:@{@"label": labels[key], @"used": w[@"utilization"],
                                  @"resets": @(ClaudeResetEpoch(w[@"resets_at"]))}];
        }
    }
    if (!readings.count) return @[];
    // Fresh windows surface only when the whole account is fresh; a lone reset-less
    // entry beside live windows is an unused scoped weekly, and stays hidden as before.
    BOOL allFresh = YES;
    for (NSDictionary *r in readings)
        if ([r[@"resets"] doubleValue] > 0 || [r[@"used"] doubleValue] > 0) { allFresh = NO; break; }
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *r in readings) {
        NSMutableDictionary *w = ClaudeWindowReading(r[@"label"], [r[@"used"] doubleValue],
                                                     [r[@"resets"] doubleValue], nowEpoch, elapsedOnly, allFresh);
        if (!w) continue;
        if (r[@"kind"]) w[@"kind"] = r[@"kind"];
        if (r[@"active"]) w[@"active"] = r[@"active"];
        [out addObject:w];
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
    // No response at all is the caller's story to tell (never fetched, paused, failed);
    // only a response that exists can be said to carry no window.
    if (![usage isKindOfClass:NSDictionary.class]) return nil;
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
    if (![usage isKindOfClass:NSDictionary.class]) return nil;
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
    if ([enabled isKindOfClass:NSNumber.class] && ![enabled boolValue]) {
        // Context only: why there is no paid overage to fall back on when the plan runs
        // out. Never a gauge, never a status reason.
        NSString *reason = [extra[@"disabled_reason"] isKindOfClass:NSString.class] ? extra[@"disabled_reason"] : nil;
        NSString *description = reason.length
            ? [@"Off · " stringByAppendingString:[reason stringByReplacingOccurrencesOfString:@"_" withString:@" "]]
            : @"Off";
        return @{@"description": description, @"overageActive": @NO};
    }
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

double RateLimitRetryDelay(double retryAfterSeconds, NSUInteger consecutive429s) {
    if (retryAfterSeconds > 0) {
        double capped = retryAfterSeconds > 3600 ? 3600 : retryAfterSeconds;
        return capped < 60 ? 60 : capped;
    }
    NSUInteger streak = consecutive429s ? consecutive429s : 1;
    double delay = 120;
    for (NSUInteger i = 1; i < streak && delay < 900; i++) delay *= 2;
    return delay > 900 ? 900 : delay;
}

BOOL StaleSnapshotWarns(double ageSeconds, double pollIntervalSeconds) {
    return ageSeconds >= 2 * pollIntervalSeconds;
}

NSDictionary *ClaudeModelQuotas(NSArray<NSDictionary *> *windows) {
    if (![windows isKindOfClass:NSArray.class]) return nil;
    NSDictionary *fableWindow = nil, *opusWindow = nil, *weekly = nil;
    for (NSDictionary *w in windows) {
        if (![w isKindOfClass:NSDictionary.class]) continue;
        NSString *label = [w[@"window"] isKindOfClass:NSString.class] ? w[@"window"] : nil;
        if (!label) continue;
        if ([label isEqualToString:@"weekly"]) { weekly = w; continue; }
        if (![label hasPrefix:@"weekly "]) continue;
        // The tightest reported weekly constraint governs each model, never a sum.
        double remaining = [w[@"remainingFraction"] doubleValue];
        if ([label rangeOfString:@"Fable" options:NSCaseInsensitiveSearch].location != NSNotFound &&
            (!fableWindow || remaining < [fableWindow[@"remainingFraction"] doubleValue])) fableWindow = w;
        if ([label rangeOfString:@"Opus" options:NSCaseInsensitiveSearch].location != NSNotFound &&
            (!opusWindow || remaining < [opusWindow[@"remainingFraction"] doubleValue])) opusWindow = w;
    }
    if (!fableWindow && !opusWindow) return nil;
    // A model with no scoped window of its own is governed by the account weekly — that
    // is what the Claude app shows beside "Current week (Fable)": one all-models figure.
    // Only a model's own window may be tighter than that.
    BOOL fableShared = !fableWindow, opusShared = !opusWindow;
    if (!fableWindow) fableWindow = weekly;
    if (!opusWindow) opusWindow = weekly;
    double fable = fableWindow ? [fableWindow[@"remainingFraction"] doubleValue] : -1;
    double opus = opusWindow ? [opusWindow[@"remainingFraction"] doubleValue] : -1;
    if (weekly) {   // a model cannot have more of the week left than the account does
        double cap = [weekly[@"remainingFraction"] doubleValue];
        if (fable > cap) fable = cap;
        if (opus > cap) opus = cap;
    }
    NSMutableDictionary *out = [@{@"fable": @(fable), @"opus": @(opus),
                                  @"fableShared": @(fableShared), @"opusShared": @(opusShared)} mutableCopy];
    if (fableWindow) out[@"fableWindow"] = fableWindow;
    if (opusWindow) out[@"opusWindow"] = opusWindow;
    id resets = fableWindow[@"resetsAt"] ?: opusWindow[@"resetsAt"] ?: weekly[@"resetsAt"];
    if ([resets isKindOfClass:NSNumber.class]) out[@"resetsAt"] = resets;
    return out;
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
                 @"status": @"Claude Code token expired · open Claude Code to refresh it"};
    return @{@"ok": @YES, @"token": token, @"expiresAt": @(expiresAtEpoch)};
}

NSString *CodexSchemaDriftReason(NSDictionary *rateLimits) {
    if (![rateLimits isKindOfClass:NSDictionary.class] || !((NSDictionary *)rateLimits).count) return nil;
    // Anything readable means the format still works, whatever else it carries.
    if (CodexWindowUsable(rateLimits[@"primary"]) || CodexWindowUsable(rateLimits[@"secondary"]) ||
        CodexCreditsUsable(rateLimits[@"credits"])) return nil;

    // A window that is present as an object but unreadable changed its insides — a
    // renamed used_percent looks exactly like this. An explicit null did not.
    for (NSString *key in @[@"primary", @"secondary"])
        if ([rateLimits[key] isKindOfClass:NSDictionary.class])
            return @"Limit windows changed shape (no used_percent)";
    if ([rateLimits[@"credits"] isKindOfClass:NSDictionary.class])
        return @"Credit balance changed shape";

    static NSSet *known;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        known = [NSSet setWithArray:@[@"primary", @"secondary", @"credits", @"limit_id", @"limit_name",
                                      @"plan_type", @"individual_limit", @"rate_limit_reached_type",
                                      @"spend_control_reached"]];
    });
    // Filter before sorting, not after: this function exists to survive payloads nobody
    // predicted, and -compare: on a non-string key would raise inside the sort.
    NSMutableArray<NSString *> *unknown = [NSMutableArray array];
    for (id key in rateLimits.allKeys)
        if ([key isKindOfClass:NSString.class] && ![known containsObject:key] &&
            ![key hasPrefix:@"_glancebar"]) [unknown addObject:key];
    [unknown sortUsingSelector:@selector(compare:)];   // stable naming across refreshes
    if (!unknown.count) return nil;   // known keys, no values: understood and empty

    // One name you can grep the payload for beats two that truncate mid-word. Field
    // names vary wildly in length, so the budget is characters, not a field count:
    // "weekly_allowance_v2" alone spends what two short names would.
    const NSUInteger kNameBudget = 26;   // ≈ 270pt at 10.5pt with the label, inside a 288pt row
    NSMutableArray<NSString *> *shown = [NSMutableArray array];
    NSUInteger used = 0;
    for (NSString *key in unknown) {
        NSUInteger cost = key.length + (shown.count ? 2 : 0);
        if (shown.count && used + cost > kNameBudget) break;
        [shown addObject:key];
        used += cost;
    }
    NSUInteger hidden = unknown.count - shown.count;
    return [NSString stringWithFormat:@"Unknown limit fields: %@%@",
            [shown componentsJoinedByString:@", "],
            hidden ? [NSString stringWithFormat:@" +%lu", (unsigned long)hidden] : @""];
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
    if (!sawUsable) {
        NSString *drift = CodexSchemaDriftReason(rateLimits);
        return drift ?: @"Codex session logs do not carry limit status";
    }
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

// See pure.h. Walks back past version-shaped and structural path components.
NSString *ProcessNameFromPath(NSString *command) {
    NSString *trimmed = Trimmed(command);
    static NSRegularExpression *versionLike;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        versionLike = [NSRegularExpression regularExpressionWithPattern:@"^v?[0-9]+(\\.[0-9]+)*$" options:0 error:nil];
    });
    for (NSString *part in trimmed.pathComponents.reverseObjectEnumerator) {
        if (!part.length || [part isEqualToString:@"/"]) continue;
        if ([part isEqualToString:@"versions"] || [part isEqualToString:@"bin"] || [part isEqualToString:@"MacOS"]) continue;
        if ([versionLike firstMatchInString:part options:0 range:NSMakeRange(0, part.length)]) continue;
        return part;
    }
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
        if (!group.length) group = ProcessNameFromPath(command);
        if (!group.length) continue;

        NSMutableDictionary *g = groups[group];
        if (!g) {
            g = [@{@"cpu": @0.0, @"bytes": @(0ULL), @"commands": [NSMutableSet set]} mutableCopy];
            groups[group] = g;
        }
        g[@"cpu"] = @([g[@"cpu"] doubleValue] + cpu);
        g[@"bytes"] = @([g[@"bytes"] unsignedLongLongValue] + bytes);
        if (command.length) [g[@"commands"] addObject:ProcessNameFromPath(command)];
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

NSString *PmsetSudoersRule(NSString *user) {
    if (!user.length || [user hasPrefix:@"-"] || [user hasPrefix:@"."]) return nil;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"] invertedSet];
    if ([user rangeOfCharacterFromSet:bad].location != NSNotFound) return nil;
    NSMutableArray<NSString *> *commands = [NSMutableArray array];
    for (NSString *setting in @[@"lowpowermode", @"disablesleep"])
        for (NSString *value in @[@"0", @"1"])
            [commands addObject:[NSString stringWithFormat:@"/usr/bin/pmset -a %@ %@", setting, value]];
    return [NSString stringWithFormat:@"%@ ALL=(root) NOPASSWD: %@", user,
            [commands componentsJoinedByString:@", "]];
}

BOOL GUIRequiresLaunchServicesRelaunch(NSString *runningBundleID,
                                      NSString *expectedBundleID) {
    return expectedBundleID.length > 0 &&
           ![runningBundleID isEqualToString:expectedBundleID];
}

#pragma mark - Adaptive bar width

static int CompareBarSpans(const void *a, const void *b) {
    double ax = ((const BarWindowSpan *)a)->x, bx = ((const BarWindowSpan *)b)->x;
    return (ax > bx) - (ax < bx);
}

double BarCapacityFromWindowSpans(double leftBoundary, double rightEdge,
                                  BarWindowSpan own,
                                  const BarWindowSpan *spans, size_t count) {
    if (!isfinite(leftBoundary) || !isfinite(rightEdge) || rightEdge <= leftBoundary ||
        !isfinite(own.x) || !isfinite(own.width) || own.width <= 0 ||
        own.x < leftBoundary - 1.0 || own.x + own.width > rightEdge + 1.0 ||
        (count && !spans))
        return -1;

    double ownRight = own.x + own.width;
    BarWindowSpan *left = count ? calloc(count, sizeof(BarWindowSpan)) : NULL;
    if (count && !left) return -1;
    size_t leftCount = 0;
    double intrusion = 0;
    for (size_t i = 0; i < count; i++) {
        BarWindowSpan span = spans[i];
        if (!isfinite(span.x) || !isfinite(span.width) || span.width <= 0) continue;
        double spanRight = span.x + span.width;
        if (!isfinite(spanRight)) continue;
        // A substantial overlap identifies our visible Control Centre host or one of
        // its wrappers. A real neighbour may touch or round across our edge by a point;
        // do not erase that obstacle merely because the compositor rounded differently.
        double overlap = MIN(spanRight, ownRight) - MAX(span.x, own.x);
        double selfThreshold = MAX(2.0, MIN(span.width, own.width) * 0.5);
        if (overlap >= selfThreshold) continue;
        if (spanRight <= leftBoundary || span.x >= own.x) continue;
        intrusion = MAX(intrusion, spanRight - own.x);
        double start = MAX(leftBoundary, span.x), end = MIN(ownRight, spanRight);
        if (end > start) left[leftCount++] = (BarWindowSpan){start, end - start};
    }
    // The right edge stays anchored, but Control Centre moves the hosts to our left
    // when our image grows. Subtract their occupied union, not the distance to the
    // nearest neighbour: that distance is always zero for a packed row and used to
    // trap a collapsed item forever. Unioning also avoids charging for host wrappers
    // twice. Everything to our right is already accounted for by ownRight.
    if (leftCount > 1) qsort(left, leftCount, sizeof(BarWindowSpan), CompareBarSpans);
    double occupied = 0, coveredRight = leftBoundary;
    for (size_t i = 0; i < leftCount; i++) {
        double end = left[i].x + left[i].width;
        occupied += MAX(0.0, end - MAX(coveredRight, left[i].x));
        coveredRight = MAX(coveredRight, end);
    }
    free(left);
    double capacity = ownRight - leftBoundary - occupied;
    // Do not let distant free space conceal a currently overlapping neighbour.
    // A one-point compositor overlap is rounding; a larger one is a real squeeze.
    if (intrusion > kBarFitTolerancePt) capacity = MIN(capacity, own.width - intrusion);
    return MIN(rightEdge - leftBoundary, MAX(0.0, capacity));
}

BOOL BarEvictionSuspected(BOOL barObservable, BOOL seenOnBar, BOOL onBar, double sinceCreatedSec) {
    if (!barObservable) return NO;   // cannot see the bar: know nothing, change nothing
    if (onBar) return NO;
    if (seenOnBar) return YES;
    return sinceCreatedSec >= kBarEvictionGraceSec;
}

const double kBarFitTolerancePt = 1;
const double kBarShrinkMarginPt = 4;
const double kBarEvictionGraceSec = 30;
const double kBarExpandMarginPt = 8;
const int    kBarExpandTicks    = 2;
const double kBarExpandMinIntervalSec = 10;

BarTierState ChooseBarTier(BarTierState prev, double capacityPt,
                           const double widths[kBarTierCount], BOOL evicted, double nowEpoch) {
    // Every non-qualifying path resets the streak AND its clock, so the next
    // qualifying decision starts a fresh window and counts immediately.
    BarTierState s = { .tier = MIN(MAX(prev.tier, BarTierFull), BarTierGlyph),
                       .expandStreak = 0, .lastCountedAt = 0 };
    if (evicted) { s.tier = BarTierGlyph; return s; }
    if (capacityPt < 0) return s;
    // Shrink only when the current tier genuinely no longer fits. A neighbour packed
    // against our left edge (Control Centre lays hosts edge to edge) measures exactly
    // our own width, and the old "+ margin" test read that as a squeeze — one shrink
    // per tick down to the glyph, and no way back up, on a bar that had never changed.
    if (widths[s.tier] > capacityPt + kBarFitTolerancePt) {
        // Widest narrower tier that fits with margin; the glyph is the floor —
        // Glancebar never voluntarily hides, even if macOS may still evict the glyph.
        while (s.tier < BarTierGlyph && widths[s.tier] + kBarShrinkMarginPt > capacityPt)
            s.tier++;
        return s;
    }
    if (s.tier > BarTierFull && widths[s.tier - 1] + kBarExpandMarginPt <= capacityPt) {
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

// --- Codex limit buckets ---

NSString *CodexLimitBucketID(NSDictionary *rateLimits) {
    NSString *limitID = [rateLimits[@"limit_id"] isKindOfClass:NSString.class] ? rateLimits[@"limit_id"] : nil;
    return limitID.length ? limitID : @"codex";
}

NSString *CodexBucketLabel(NSString *bucketID) {
    if (!bucketID.length || [bucketID isEqualToString:@"codex"]) return @"plan";
    if ([bucketID isEqualToString:@"premium"]) return @"credits";
    if ([bucketID hasPrefix:@"codex_"] && bucketID.length > 6) return [bucketID substringFromIndex:6];
    return bucketID;
}

static NSString *BucketTs(NSDictionary *entry) {
    return [entry[@"ts"] isKindOfClass:NSString.class] ? entry[@"ts"] : nil;
}
static NSDictionary *BucketLimits(NSDictionary *entry) {
    return [entry[@"limits"] isKindOfClass:NSDictionary.class] ? entry[@"limits"] : nil;
}

static NSDictionary *MergeBucketEntries(NSDictionary *a, NSDictionary *b) {
    NSDictionary *limits = MergeCodexRateLimits(BucketLimits(a), BucketTs(a), BucketLimits(b), BucketTs(b));
    if (!limits) return nil;
    NSString *ta = BucketTs(a), *tb = BucketTs(b);
    NSString *ts = !ta.length ? tb : !tb.length ? ta : ([tb compare:ta] == NSOrderedDescending ? tb : ta);
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithObject:limits forKey:@"limits"];
    if (ts.length) out[@"ts"] = ts;
    return out;
}

NSDictionary *FoldCodexSnapshotIntoBuckets(NSDictionary *buckets, NSDictionary *snapshot, NSString *ts) {
    if (![snapshot isKindOfClass:NSDictionary.class]) return [buckets isKindOfClass:NSDictionary.class] ? buckets : nil;
    NSMutableDictionary *out = [buckets isKindOfClass:NSDictionary.class] ? [buckets mutableCopy]
                                                                          : [NSMutableDictionary dictionary];
    NSString *bucketID = CodexLimitBucketID(snapshot);
    NSDictionary *incoming = ts.length ? @{@"limits": snapshot, @"ts": ts} : @{@"limits": snapshot};
    NSDictionary *kept = [out[bucketID] isKindOfClass:NSDictionary.class] ? out[bucketID] : nil;
    NSDictionary *merged = MergeBucketEntries(kept, incoming);
    if (merged) out[bucketID] = merged;
    return out;
}

NSDictionary *MergeCodexLimitBuckets(NSDictionary *a, NSDictionary *b) {
    if (![a isKindOfClass:NSDictionary.class]) a = nil;
    if (![b isKindOfClass:NSDictionary.class]) b = nil;
    if (!a && !b) return nil;
    NSMutableSet *ids = [NSMutableSet setWithArray:a.allKeys ?: @[]];
    [ids addObjectsFromArray:b.allKeys ?: @[]];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *bucketID in ids) {
        if (![bucketID isKindOfClass:NSString.class]) continue;
        NSDictionary *ea = [a[bucketID] isKindOfClass:NSDictionary.class] ? a[bucketID] : nil;
        NSDictionary *eb = [b[bucketID] isKindOfClass:NSDictionary.class] ? b[bucketID] : nil;
        NSDictionary *merged = ea && eb ? MergeBucketEntries(ea, eb) : (ea ?: eb);
        if (BucketLimits(merged)) out[bucketID] = merged;
    }
    return out;
}

NSString *CodexNewestBucketID(NSDictionary *buckets) {
    if (![buckets isKindOfClass:NSDictionary.class]) return nil;
    NSString *best = nil, *bestTs = nil;
    for (NSString *bucketID in buckets) {
        NSString *ts = BucketTs(buckets[bucketID]);
        if (!ts.length) continue;
        NSComparisonResult order = bestTs ? [ts compare:bestTs] : NSOrderedDescending;
        // Equal stamps: pick deterministically so a fold order cannot change the answer.
        if (order == NSOrderedDescending || (order == NSOrderedSame && [bucketID compare:best] == NSOrderedAscending)) {
            best = bucketID;
            bestTs = ts;
        }
    }
    return best;
}

NSDictionary *CodexNewestBucketLimits(NSDictionary *buckets) {
    NSString *bucketID = CodexNewestBucketID(buckets);
    return bucketID ? BucketLimits(buckets[bucketID]) : nil;
}

NSArray<NSDictionary *> *CodexBucketWindows(NSDictionary *buckets, double nowEpoch) {
    if (![buckets isKindOfClass:NSDictionary.class]) return @[];
    NSMutableArray<NSDictionary *> *groups = [NSMutableArray array];
    for (NSString *bucketID in buckets) {
        if (![bucketID isKindOfClass:NSString.class]) continue;
        NSDictionary *entry = buckets[bucketID];
        NSArray<NSDictionary *> *windows = CodexLimitWindows(BucketLimits(entry), nowEpoch);
        if (!windows.count) continue;
        double least = 2;
        NSMutableArray *tagged = [NSMutableArray array];
        for (NSDictionary *w in windows) {
            NSMutableDictionary *d = [w mutableCopy];
            d[@"bucket"] = bucketID;
            d[@"bucketLabel"] = CodexBucketLabel(bucketID);
            [tagged addObject:d];
            least = MIN(least, [w[@"remainingFraction"] doubleValue]);
        }
        [groups addObject:@{@"id": bucketID, @"least": @(least), @"ts": BucketTs(entry) ?: @"", @"windows": tagged}];
    }
    [groups sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult order = [a[@"least"] compare:b[@"least"]];
        if (order != NSOrderedSame) return order;
        order = [b[@"ts"] compare:a[@"ts"]];   // newer snapshot first
        if (order != NSOrderedSame) return order;
        return [a[@"id"] compare:b[@"id"]];
    }];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *group in groups) [out addObjectsFromArray:group[@"windows"]];
    return out;
}

NSDictionary *PickCodexBucketWindow(NSDictionary *buckets, double nowEpoch) {
    NSDictionary *best = nil;
    double bestRemaining = 2;
    for (NSDictionary *w in CodexBucketWindows(buckets, nowEpoch)) {
        double remaining = [w[@"remainingFraction"] doubleValue];
        if (remaining >= bestRemaining) continue;   // first (most constrained bucket) wins ties
        bestRemaining = remaining;
        best = w;
    }
    return best;
}

NSString *CodexBucketsStatusReason(NSDictionary *buckets, double nowEpoch) {
    if (![buckets isKindOfClass:NSDictionary.class] || !buckets.count)
        return CodexLimitStatusReason(nil, nil, nowEpoch);
    NSString *fallback = nil, *fallbackTs = nil;
    BOOL fallbackCarriedWindows = NO;
    for (NSString *bucketID in buckets) {
        NSDictionary *entry = buckets[bucketID];
        NSDictionary *limits = BucketLimits(entry);
        NSString *reason = CodexLimitStatusReason(limits, BucketTs(entry), nowEpoch);
        if (!reason) return nil;   // a current window exists somewhere — the gauge shows
        // Prefer the bucket that actually carried windows (its dated "reset since" message
        // says more than "do not carry"), then the newest snapshot.
        BOOL carried = CodexWindowUsable(limits[@"primary"]) || CodexWindowUsable(limits[@"secondary"]);
        NSString *ts = BucketTs(entry);
        BOOL better = !fallback || (carried && !fallbackCarriedWindows) ||
            (carried == fallbackCarriedWindows && ts.length &&
             (!fallbackTs.length || [ts compare:fallbackTs] == NSOrderedDescending));
        if (better) { fallback = reason; fallbackTs = ts; fallbackCarriedWindows = carried; }
    }
    return fallback;
}

NSString *CodexBillingNote(NSDictionary *buckets, double nowEpoch) {
    NSString *newest = CodexNewestBucketID(buckets);
    if (!newest.length) return nil;
    NSDictionary *pick = PickCodexBucketWindow(buckets, nowEpoch);
    if (!pick || [pick[@"bucket"] isEqualToString:newest]) return nil;
    if (![newest isEqualToString:@"premium"])
        return nil; // Observation order does not establish which model is handling requests.
    // Credits are one account-level meter, whichever bucket last reported them.
    NSDictionary *credits = CodexCreditsStatus(BucketLimits(buckets[newest]));
    for (NSString *bucketID in buckets) if (!credits) credits = CodexCreditsStatus(BucketLimits(buckets[bucketID]));
    if (!credits) return @"Requests now bill to credits";
    if ([credits[@"unlimited"] boolValue]) return @"Requests now bill to credits · unlimited";
    if ([credits[@"exhausted"] boolValue]) return @"Requests now bill to credits · none available";
    NSString *balance = [credits[@"balance"] isKindOfClass:NSString.class] ? credits[@"balance"] : nil;
    return balance.length ? [NSString stringWithFormat:@"Requests now bill to credits · balance %@", balance]
                          : @"Requests now bill to credits";
}
