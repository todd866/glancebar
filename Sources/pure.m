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

static NSDictionary *CursorWindow(NSString *name, double remainingFrac, double resets) {
    remainingFrac = remainingFrac < 0 ? 0 : remainingFrac > 1 ? 1 : remainingFrac;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"window"] = name;
    d[@"remainingFraction"] = @(remainingFrac);
    if (resets > 0) d[@"resetsAt"] = @(resets);
    return d;
}

// GetCurrentPeriodUsage has changed shape before: early bodies carried remaining/limit;
// current ones (seen 2026-10) drop `remaining` and split the allowance into an Auto pool
// and an API pool for named models, each with its own percentage. totalPercentUsed blends
// the two and hides a nearly spent API pool, so the pools win over it when present.
static NSArray<NSDictionary *> *CursorPlanWindowsFiltered(NSDictionary *usage, double nowEpoch, BOOL elapsedOnly) {
    NSDictionary *plan = [usage[@"planUsage"] isKindOfClass:NSDictionary.class] ? usage[@"planUsage"] : nil;
    if (!plan) return @[];
    double resets = CursorEpochSeconds(usage[@"billingCycleEnd"]);
    if (elapsedOnly) {
        if (!(resets > 0 && resets <= nowEpoch)) return @[];
    } else if (resets > 0 && resets <= nowEpoch) {
        return @[];
    }

    NSNumber *remaining = [plan[@"remaining"] isKindOfClass:NSNumber.class] ? plan[@"remaining"] : nil;
    NSNumber *limit = [plan[@"limit"] isKindOfClass:NSNumber.class] ? plan[@"limit"] : nil;
    if (remaining && limit && limit.doubleValue > 0)
        return @[CursorWindow(@"billing period", remaining.doubleValue / limit.doubleValue, resets)];

    NSNumber *api = [plan[@"apiPercentUsed"] isKindOfClass:NSNumber.class] ? plan[@"apiPercentUsed"] : nil;
    NSNumber *autoPool = [plan[@"autoPercentUsed"] isKindOfClass:NSNumber.class] ? plan[@"autoPercentUsed"] : nil;
    if (api || autoPool) {
        NSMutableArray *pools = [NSMutableArray array];
        if (api) [pools addObject:CursorWindow(@"API models", 1.0 - api.doubleValue / 100.0, resets)];
        if (autoPool) [pools addObject:CursorWindow(@"Auto", 1.0 - autoPool.doubleValue / 100.0, resets)];
        return pools;
    }
    if ([plan[@"totalPercentUsed"] isKindOfClass:NSNumber.class])
        return @[CursorWindow(@"billing period", 1.0 - [plan[@"totalPercentUsed"] doubleValue] / 100.0, resets)];
    if ([plan[@"includedSpend"] isKindOfClass:NSNumber.class] && limit && limit.doubleValue > 0)
        return @[CursorWindow(@"billing period", 1.0 - [plan[@"includedSpend"] doubleValue] / limit.doubleValue, resets)];
    return @[];
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
    NSArray<NSDictionary *> *plan = CursorPlanWindowsFiltered(usage, nowEpoch, NO);
    if (plan.count) return plan;
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
    return CursorPlanWindowsFiltered(usage, nowEpoch, YES);
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

double JWTExpiryEpoch(NSString *jwt) {
    NSArray<NSString *> *parts = [jwt componentsSeparatedByString:@"."];
    if (parts.count != 3) return 0;
    NSMutableString *b64 = [[[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                             stringByReplacingOccurrencesOfString:@"_" withString:@"/"] mutableCopy];
    while (b64.length % 4) [b64 appendString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (!data) return 0;
    id claims = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![claims isKindOfClass:NSDictionary.class]) return 0;
    id exp = claims[@"exp"];
    return [exp isKindOfClass:NSNumber.class] ? [exp doubleValue] : 0;
}

NSString *FreshestSessionToken(NSArray<NSString *> *tokens, double nowEpoch, BOOL *expired) {
    NSString *best = nil, *unknown = nil;
    double bestExp = nowEpoch;
    BOOL sawExpired = NO;
    for (NSString *token in tokens) {
        if (![token isKindOfClass:NSString.class] || !token.length) continue;
        double exp = JWTExpiryEpoch(token);
        if (exp <= 0) { if (!unknown) unknown = token; continue; }
        if (exp <= nowEpoch) { sawExpired = YES; continue; }
        if (exp > bestExp) { bestExp = exp; best = token; }
    }
    NSString *chosen = best ?: unknown;
    if (expired) *expired = !chosen && sawExpired;
    return chosen;
}

NSString *AccountFetchFailureStatus(NSInteger statusCode, NSString *message, NSString *client) {
    if (statusCode == 401 || statusCode == 403)
        return [NSString stringWithFormat:@"Signed out · sign in to %@ again", client.length ? client : @"the app"];
    return message.length ? [@"Usage API: " stringByAppendingString:message] : @"Usage API unavailable";
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

static NSString *AudioUID(NSDictionary *device) {
    id uid = device[@"uid"];
    return [uid isKindOfClass:NSString.class] && [uid length] ? uid : nil;
}
static NSInteger AudioChannels(NSDictionary *device) {
    id channels = device[@"outputChannels"];
    return [channels respondsToSelector:@selector(integerValue)] ? [channels integerValue] : 0;
}
static BOOL AudioIsExternalOutput(NSDictionary *device) {
    NSInteger transport = [device[@"transport"] integerValue];
    if (AudioChannels(device) <= 0 || !AudioUID(device)) return NO;
    return transport == GlanceAudioTransportBluetooth || transport == GlanceAudioTransportUSB ||
           transport == GlanceAudioTransportDisplay;
}
static BOOL AudioIsVirtualOutput(NSDictionary *device) {
    NSInteger transport = [device[@"transport"] integerValue];
    return transport == GlanceAudioTransportAggregate || transport == GlanceAudioTransportVirtual;
}

NSString *ChooseNewOutputDevice(NSArray<NSDictionary *> *previous,
                                NSArray<NSDictionary *> *current,
                                BOOL switchToNewOutputs) {
    if (!switchToNewOutputs) return nil;
    NSMutableSet<NSString *> *alreadyOutput = [NSMutableSet set];
    for (NSDictionary *device in previous) {
        NSString *uid = AudioUID(device);
        if (uid && AudioChannels(device) > 0) [alreadyOutput addObject:uid];
    }
    for (NSDictionary *device in current) {
        NSString *uid = AudioUID(device);
        if (!AudioIsExternalOutput(device) || [alreadyOutput containsObject:uid]) continue;
        return uid;
    }
    return nil;
}

NSArray<NSDictionary *> *AudioOutputMenuDevices(NSArray<NSDictionary *> *devices,
                                                NSString *defaultUID) {
    NSMutableArray<NSDictionary *> *shown = [NSMutableArray array];
    NSDictionary *currentVirtual = nil;
    for (NSDictionary *device in devices) {
        if (AudioChannels(device) <= 0 || !AudioUID(device)) continue;
        if (AudioIsVirtualOutput(device)) {
            if ([AudioUID(device) isEqual:defaultUID]) currentVirtual = device;
            continue;
        }
        [shown addObject:device];
    }
    if (currentVirtual) [shown addObject:currentVirtual];
    return shown;
}

static BOOL AudioTextIsHeadphones(NSString *text) {
    if (![text isKindOfClass:NSString.class] || !text.length) return NO;
    NSString *s = text.lowercaseString;
    for (NSString *needle in @[@"airpod", @"headphone", @"headset", @"earbud", @"earphone"])
        if ([s containsString:needle]) return YES;
    return NO;
}

NSString *AudioOutputSymbol(GlanceAudioTransport transport, NSString *name, NSString *dataSource) {
    if (transport == GlanceAudioTransportDisplay) return @"display";
    if (AudioTextIsHeadphones(name) || AudioTextIsHeadphones(dataSource)) return @"headphones";
    if (transport == GlanceAudioTransportBuiltIn) return @"speaker.wave.2.fill";
    return @"speaker.wave.2";
}

const NSInteger kYouTubeLikedDefaultCount = 200;

static NSInteger PlaylistBound(NSInteger count) {
    if (count < 1) return kYouTubeLikedDefaultCount;
    if (count > 100000) return 100000;
    return count;
}

NSInteger ClampedPlaylistIndex(NSInteger index, NSInteger count) {
    NSInteger n = PlaylistBound(count);
    if (index < 1) return 1;
    if (index > n) return n;
    return index;
}

NSInteger PlaylistIndexForSeed(uint32_t seed, NSInteger count) {
    NSInteger n = PlaylistBound(count);
    uint32_t state = seed ? seed : 1u;
    state = state * 1664525u + 1013904223u;
    return ClampedPlaylistIndex((NSInteger)(state % (uint32_t)n) + 1, n);
}

NSString *YouTubeLikedMusicURL(uint32_t seed, NSInteger count) {
    return [NSString stringWithFormat:@"https://music.youtube.com/watch?list=LM&index=%ld",
            (long)PlaylistIndexForSeed(seed, count)];
}

NSInteger ParsePlaylistCount(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return 0;
    NSString *s = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!s.length || s.length > 40) return 0;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"^(?:\\d{1,3}(?:,\\d{3})+|\\d{1,6})(?:\\s+songs?)?$"
        options:NSRegularExpressionCaseInsensitive error:nil];
    if (![re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)]) return 0;
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
        else if (c == ',') continue;
        else break;
    }
    NSInteger value = digits.integerValue;
    if (value < 1 || value > 100000) return 0;
    return value;
}

BOOL ChromeJavaScriptEventsDenied(NSString *errorText) {
    if (![errorText isKindOfClass:NSString.class] || !errorText.length) return NO;
    NSString *s = errorText.lowercaseString;
    // Recent Chrome reports a profile with the setting off as a bare "Access not allowed"
    // (-1723) on `execute javascript`, without naming the setting (seen 2026-10-06).
    return [s containsString:@"allow javascript from apple events"] ||
           [s containsString:@"javascript through applescript"] ||
           [s containsString:@"access not allowed"] || [s containsString:@"(-1723)"];
}

BOOL ChromeAutomationDenied(NSString *errorText) {
    if (![errorText isKindOfClass:NSString.class] || !errorText.length) return NO;
    NSString *s = errorText.lowercaseString;
    return [s containsString:@"not authorized to send apple events"] || [s containsString:@"(-1743)"];
}

NSString *const YouTubeStatusSeparator = @"\x1f";

static NSString *YouTubeStatusField(NSArray<NSString *> *fields, NSUInteger index) {
    if (index >= fields.count) return @"";
    NSString *field = fields[index];
    if (![field isKindOfClass:NSString.class]) return @"";
    return [field stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// A finite number, or nil. Empty and non-numeric fields are absent, not zero:
// the player bar has no clock until the video element reports one.
static NSNumber *YouTubeStatusNumber(NSArray<NSString *> *fields, NSUInteger index) {
    NSString *field = YouTubeStatusField(fields, index);
    if (!field.length) return nil;
    NSScanner *scanner = [NSScanner scannerWithString:field];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];   // JavaScript writes "12.5" everywhere
    double value = 0;
    if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value)) return nil;
    return @(value);
}

NSDictionary *ParseYouTubeStatus(NSString *output, NSString *errorText) {
    NSString *out = [output isKindOfClass:NSString.class] ? output : @"";
    NSString *err = [errorText isKindOfClass:NSString.class] ? errorText : @"";
    // A real status line always carries the separator, so a denial phrase inside a title
    // is not Chrome's error. Text with no separator is osascript complaining.
    BOOL looksLikeStatus = [out containsString:YouTubeStatusSeparator];
    NSString *diagnostic = looksLikeStatus ? err : [err stringByAppendingString:out];
    NSString *denied = @"";
    if (ChromeAutomationDenied(diagnostic)) denied = @"automation";
    else if (ChromeJavaScriptEventsDenied(diagnostic)) denied = @"javascript";

    NSString *trimmed = [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *fields = looksLikeStatus ? [trimmed componentsSeparatedByString:YouTubeStatusSeparator] : @[];
    BOOL tab = [YouTubeStatusField(fields, 0) caseInsensitiveCompare:@"yes"] == NSOrderedSame;
    id playing = [NSNull null];
    NSString *state = YouTubeStatusField(fields, 1).lowercaseString;
    if ([state isEqual:@"playing"]) playing = @YES;
    else if ([state isEqual:@"paused"]) playing = @NO;
    NSString *title = YouTubeStatusField(fields, 2);
    NSString *artist = YouTubeStatusField(fields, 3);
    NSInteger count = ParsePlaylistCount(YouTubeStatusField(fields, 4));
    NSNumber *elapsed = YouTubeStatusNumber(fields, 5);
    NSNumber *duration = YouTubeStatusNumber(fields, 6);
    // JavaScript is refused only after a music tab was found and execute javascript ran.
    // Automation is refused before any tab can be seen. Either way the page told us nothing.
    if ([denied isEqual:@"automation"]) {
        tab = NO; playing = [NSNull null]; title = @""; artist = @""; count = 0;
        elapsed = nil; duration = nil;
    } else if ([denied isEqual:@"javascript"]) {
        tab = YES; playing = [NSNull null]; title = @""; artist = @""; count = 0;
        elapsed = nil; duration = nil;
    }
    NSMutableDictionary *status = [@{@"tab": @(tab), @"playing": playing, @"title": title,
                                     @"artist": artist, @"count": @(count), @"denied": denied} mutableCopy];
    if (elapsed) status[@"elapsed"] = elapsed;
    if (duration) status[@"duration"] = duration;
    return status;
}

static NSString *FormatClockPart(double seconds, BOOL withHours) {
    int whole = (int)seconds;
    int h = whole / 3600;
    int m = (whole % 3600) / 60;
    int s = whole % 60;
    if (withHours) return [NSString stringWithFormat:@"%d:%02d:%02d", h, m, s];
    return [NSString stringWithFormat:@"%d:%02d", m, s];
}

NSString *FormatTrackTime(double elapsed, double duration) {
    if (!isfinite(duration) || duration <= 0 || !isfinite(elapsed)) return nil;
    if (elapsed < 0) elapsed = 0;
    if (elapsed > duration) elapsed = duration;
    BOOL withHours = duration >= 3600.0;
    return [NSString stringWithFormat:@"%@ / %@", FormatClockPart(elapsed, withHours),
            FormatClockPart(duration, withHours)];
}

BOOL YieldLocalMusic(BOOL localMode, BOOL networkOnline, BOOL playing) {
    return localMode && networkOnline && !playing;
}

BOOL YouTubeNewTabAllowed(NSTimeInterval now, NSTimeInterval lastOpen) {
    if (lastOpen <= 0) return YES;
    return now - lastOpen >= 60;
}

BOOL OfflineTrackListStale(BOOL haveCache, BOOL enteringOffline, NSTimeInterval ageSeconds) {
    if (!haveCache || enteringOffline) return YES;
    return ageSeconds >= 60;
}

static uint32_t TrackRNG(uint32_t *state) {
    *state = *state * 1664525u + 1013904223u;
    return *state;
}

NSArray<NSString *> *ShuffledTrackOrder(NSArray<NSString *> *names, uint32_t seed) {
    if (![names isKindOfClass:NSArray.class] || !names.count) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id name in names) if ([name isKindOfClass:NSString.class]) [out addObject:name];
    uint32_t state = seed ? seed : 1u;
    for (NSInteger i = (NSInteger)out.count - 1; i > 0; i--) {
        NSInteger j = (NSInteger)(TrackRNG(&state) % (uint32_t)(i + 1));
        [out exchangeObjectAtIndex:(NSUInteger)i withObjectAtIndex:(NSUInteger)j];
    }
    return out;
}

NSArray<NSString *> *LikedMusicAudioFiles(NSArray<NSString *> *names) {
    if (![names isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id name in names) {
        if (![name isKindOfClass:NSString.class]) continue;
        NSString *base = [(NSString *)name lastPathComponent];
        if (!base.length || [base hasPrefix:@"."]) continue;
        if (![base.lowercaseString hasSuffix:@".m4a"]) continue;
        [out addObject:name];
    }
    return out;
}

NSDictionary *ParseLikedTrackFilename(NSString *filename) {
    if (![filename isKindOfClass:NSString.class] || !filename.length) return nil;
    NSString *base = filename.lastPathComponent;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"^(.+?) - (.+) \\[([A-Za-z0-9_-]+)\\]\\.m4a$"
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [re firstMatchInString:base options:0 range:NSMakeRange(0, base.length)];
    if (match && match.numberOfRanges == 4) {
        return @{
            @"artist": [base substringWithRange:[match rangeAtIndex:1]],
            @"title": [base substringWithRange:[match rangeAtIndex:2]],
            @"trackID": [base substringWithRange:[match rangeAtIndex:3]],
        };
    }
    NSString *title = base;
    if ([title.lowercaseString hasSuffix:@".m4a"]) title = [title substringToIndex:title.length - 4];
    return @{@"artist": @"", @"title": title, @"trackID": @""};
}

static NSDictionary *StatuslineWindow(NSDictionary *statusline, NSString *key) {
    NSDictionary *w = [statusline[key] isKindOfClass:NSDictionary.class] ? statusline[key] : nil;
    if (![w[@"usedPct"] isKindOfClass:NSNumber.class] || ![w[@"resetsAt"] isKindOfClass:NSNumber.class]) return nil;
    return w;
}

NSDictionary *ClaudeUsageOverlayingStatusline(NSDictionary *usage, NSDictionary *statusline) {
    if (![statusline isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *session = StatuslineWindow(statusline, @"fiveHour");
    NSDictionary *weekly = StatuslineWindow(statusline, @"sevenDay");
    if (!session && !weekly) return nil;
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    NSString *(^isoFor)(NSDictionary *) = ^NSString *(NSDictionary *w) {
        return [iso stringFromDate:[NSDate dateWithTimeIntervalSince1970:[w[@"resetsAt"] doubleValue]]];
    };
    NSMutableDictionary *out = [usage isKindOfClass:NSDictionary.class] ? [usage mutableCopy] : [NSMutableDictionary dictionary];
    void (^setLegacy)(NSString *, NSDictionary *) = ^(NSString *key, NSDictionary *w) {
        if (!w) return;
        NSMutableDictionary *legacy = [out[key] isKindOfClass:NSDictionary.class] ? [out[key] mutableCopy] : [NSMutableDictionary dictionary];
        legacy[@"utilization"] = w[@"usedPct"];
        legacy[@"resets_at"] = isoFor(w);
        out[key] = legacy;
    };
    setLegacy(@"five_hour", session);
    setLegacy(@"seven_day", weekly);

    // A body without limits[] is read through its legacy keys, seven_day_opus among them;
    // adding a limits[] would make it authoritative and hide those. Only a body we
    // invent from nothing gets one.
    if ([usage isKindOfClass:NSDictionary.class] && ![usage[@"limits"] isKindOfClass:NSArray.class]) return out;
    NSMutableArray *limits = [NSMutableArray array];
    BOOL sawSession = NO, sawWeekly = NO;
    NSArray *existing = [out[@"limits"] isKindOfClass:NSArray.class] ? out[@"limits"] : @[];
    for (id entry in existing) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *kind = [entry[@"kind"] isKindOfClass:NSString.class] ? entry[@"kind"] : @"";
        NSDictionary *w = [kind isEqualToString:@"session"] ? session : [kind isEqualToString:@"weekly_all"] ? weekly : nil;
        if (!w) { [limits addObject:entry]; continue; }
        NSMutableDictionary *m = [entry mutableCopy];
        m[@"percent"] = w[@"usedPct"];
        m[@"resets_at"] = isoFor(w);
        [limits addObject:m];
        if (w == session) sawSession = YES; else sawWeekly = YES;
    }
    if (session && !sawSession)
        [limits addObject:@{@"kind": @"session", @"group": @"session", @"percent": session[@"usedPct"], @"resets_at": isoFor(session)}];
    if (weekly && !sawWeekly)
        [limits addObject:@{@"kind": @"weekly_all", @"group": @"weekly", @"percent": weekly[@"usedPct"], @"resets_at": isoFor(weekly)}];
    out[@"limits"] = limits;
    return out;
}

#pragma mark - Refresh coalescing, volumes, quit, storage headline

const double kPowerRefreshCoalesceSec = 1;
const double kBarCapacityMaxAgeSec = 60;
const double kVolumeScanUnavailableSec = 20;
const double kQuitPmsetBudgetSec = 10;   // covers the 8s task watchdog plus the sudo itself
const int kStorageFullSecondaryPercent = 85;

BOOL ShouldArmPowerRefresh(BOOL pending) { return !pending; }

NSString *BarCapacityCacheKey(NSArray<NSString *> *segmentTexts, NSString *screenKey) {
    if (![screenKey isKindOfClass:NSString.class] || !screenKey.length) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([segmentTexts isKindOfClass:NSArray.class]) {
        for (id text in segmentTexts)
            [parts addObject:[text isKindOfClass:NSString.class] ? text : @""];
    }
    return [NSString stringWithFormat:@"%@\n%@", [parts componentsJoinedByString:@"\t"], screenKey];
}

BOOL BarCapacityMeasurementFresh(NSString *cachedKey, NSString *currentKey,
                                 double ageSec, double maxAgeSec) {
    if (![cachedKey isKindOfClass:NSString.class] || !cachedKey.length) return NO;
    if (![currentKey isKindOfClass:NSString.class] || !currentKey.length) return NO;
    if (!isfinite(ageSec) || !isfinite(maxAgeSec) || maxAgeSec < 0) return NO;
    if (ageSec < 0 || ageSec >= maxAgeSec) return NO;
    return [cachedKey isEqualToString:currentKey];
}

static NSArray<NSString *> *VolumeBaseResourceKeys(void) {
    return @[NSURLVolumeNameKey, NSURLVolumeTotalCapacityKey,
             NSURLVolumeAvailableCapacityKey, NSURLVolumeIsInternalKey,
             NSURLVolumeIsLocalKey];
}

NSArray<NSString *> *VolumeResourceKeys(BOOL isLocal) {
    NSArray<NSString *> *base = VolumeBaseResourceKeys();
    if (!isLocal) return base;
    return [base arrayByAddingObject:NSURLVolumeAvailableCapacityForImportantUsageKey];
}

BOOL VolumeScanUnavailable(BOOL scanning, double elapsedSec) {
    return scanning && isfinite(elapsedSec) && elapsedSec >= kVolumeScanUnavailableSec;
}

NSString *VolumeScanStatus(BOOL loading, BOOL unavailable) {
    return (!unavailable && loading) ? @"Scanning mounted volumes…" : @"Storage information unavailable";
}

double QuitPmsetBudgetRemaining(double elapsedSec) {
    if (!(elapsedSec > 0)) return kQuitPmsetBudgetSec;
    double left = kQuitPmsetBudgetSec - elapsedSec;
    return left > 0 ? left : 0;
}

NSString *KeepAwakeTooltip(BOOL sudoersRuleInstalled) {
    NSString *base = @"Stops this Mac sleeping — when idle or with the lid closed; the display can still sleep. ";
    return [base stringByAppendingString:sudoersRuleInstalled
            ? @"Glancebar switches it off when it quits."
            : @"Glancebar leaves it on when it quits."];
}

BOOL ShouldStartPmset(BOOL inFlight) { return !inFlight; }

NSInteger StorageHeadlineIndex(NSArray<NSNumber *> *bootFlags) {
    if (![bootFlags isKindOfClass:NSArray.class] || bootFlags.count == 0) return NSNotFound;
    NSInteger first = NSNotFound;
    for (NSUInteger i = 0; i < bootFlags.count; i++) {
        if (first == NSNotFound) first = (NSInteger)i;
        id flag = bootFlags[i];
        if ([flag isKindOfClass:NSNumber.class] && [flag boolValue]) return (NSInteger)i;
    }
    return first;
}

static int StorageUsedPercent(double fraction) {
    if (!isfinite(fraction) || fraction < 0) return 0;
    return (int)lround(fraction * 100.0);
}

NSDictionary *StorageSecondaryNotice(NSArray<NSDictionary *> *volumes) {
    if (![volumes isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NSMutableArray<NSNumber *> *boots = [NSMutableArray array];
    for (id row in volumes) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        [rows addObject:row];
        id boot = row[@"boot"];
        [boots addObject:[boot isKindOfClass:NSNumber.class] ? boot : @NO];
    }
    NSInteger headline = StorageHeadlineIndex(boots);
    if (headline == NSNotFound) return nil;
    double headlineFrac = [rows[(NSUInteger)headline][@"fraction"] doubleValue];
    if (!isfinite(headlineFrac)) headlineFrac = 0;
    NSInteger best = NSNotFound;
    double bestFrac = 0;
    for (NSUInteger i = 0; i < rows.count; i++) {
        if ((NSInteger)i == headline) continue;
        double frac = [rows[i][@"fraction"] doubleValue];
        if (!isfinite(frac) || !(frac > headlineFrac)) continue;
        if (StorageUsedPercent(frac) <= kStorageFullSecondaryPercent) continue;
        if (best == NSNotFound || frac > bestFrac) { best = (NSInteger)i; bestFrac = frac; }
    }
    if (best == NSNotFound) return nil;
    id name = rows[(NSUInteger)best][@"name"];
    if (![name isKindOfClass:NSString.class] || ![(NSString *)name length]) return nil;
    return @{@"text": [NSString stringWithFormat:@"%@ %d%% full", name, StorageUsedPercent(bestFrac)],
             @"fraction": @(bestFrac)};
}

NSString *NextOutputUID(NSArray<NSDictionary *> *menuDevices, NSString *currentUID) {
    if (![menuDevices isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<NSString *> *uids = [NSMutableArray array];
    for (id row in menuDevices) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        id uid = ((NSDictionary *)row)[@"uid"];
        if ([uid isKindOfClass:NSString.class] && [(NSString *)uid length]) [uids addObject:uid];
    }
    if (uids.count < 2) return nil;
    NSUInteger index = [currentUID isKindOfClass:NSString.class] ? [uids indexOfObject:currentUID] : NSNotFound;
    if (index == NSNotFound) return uids[0];
    return uids[(index + 1) % uids.count];
}

NSString *CompactResetClock(NSDate *resetAt, NSDate *now) {
    if (![resetAt isKindOfClass:NSDate.class]) return nil;
    NSDate *reference = [now isKindOfClass:NSDate.class] ? now : NSDate.date;
    NSCalendar *cal = NSCalendar.currentCalendar;
    NSInteger days = [cal components:NSCalendarUnitDay
                            fromDate:[cal startOfDayForDate:reference]
                              toDate:[cal startOfDayForDate:resetAt]
                             options:0].day;
    // The column is a fixed instrument, so the words do not follow the locale:
    // 24-hour digits, English weekday and month.
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = locale;
    fmt.timeZone = cal.timeZone;
    fmt.calendar = cal;
    if (days <= 0) {
        fmt.dateFormat = @"HH:mm";
        return [fmt stringFromDate:resetAt];
    }
    if (days <= 6) {
        NSDateComponents *hm = [cal components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:resetAt];
        (void)hm;   // the day is the glance; the exact time is in the tooltip
        fmt.dateFormat = @"EEE";
        return [fmt stringFromDate:resetAt];
    }
    fmt.dateFormat = @"d MMM";
    return [fmt stringFromDate:resetAt];
}

NSString *ChargeModeEffective(NSString *storedMode, NSDate *storedAt, NSDate *now) {
    if ([storedMode isEqualToString:@"full"] && [storedAt isKindOfClass:NSDate.class]) {
        NSDate *reference = [now isKindOfClass:NSDate.class] ? now : NSDate.date;
        if ([reference timeIntervalSinceDate:storedAt] < 24 * 60 * 60) return @"full";
    }
    return @"limit80";
}

BOOL ChargeHeld(BOOL plugged, BOOL charging, int percent, NSString *mode) {
    return plugged && !charging && percent >= 79 && [mode isEqualToString:@"limit80"];
}

static NSString *ScaledByteCount(long long bytes, int decimals, BOOL trimZeros) {
    if (bytes < 0) bytes = 0;
    const double scale[] = {1e12, 1e9, 1e6, 1e3};
    const char *unit[] = {"TB", "GB", "MB", "KB"};
    for (int i = 0; i < 4; i++) {
        if ((double)bytes < scale[i]) continue;
        double value = (double)bytes / scale[i];
        if (!trimZeros && value >= 100.0)
            return [NSString stringWithFormat:@"%.0f %s", value, unit[i]];
        if (!trimZeros) {
            double tenths = round(value * 10.0) / 10.0;
            if (tenths >= 100.0) return [NSString stringWithFormat:@"%.0f %s", tenths, unit[i]];
            if (fabs(tenths - round(tenths)) < 0.05)
                return [NSString stringWithFormat:@"%.0f %s", round(tenths), unit[i]];
            return [NSString stringWithFormat:@"%.1f %s", tenths, unit[i]];
        }
        NSString *num = [NSString stringWithFormat:@"%.*f", decimals, value];
        while ([num hasSuffix:@"0"]) num = [num substringToIndex:num.length - 1];
        if ([num hasSuffix:@"."]) num = [num substringToIndex:num.length - 1];
        return [NSString stringWithFormat:@"%@ %s", num, unit[i]];
    }
    return [NSString stringWithFormat:@"%lld B", bytes];
}

NSString *CompactByteCount(long long bytes) { return ScaledByteCount(bytes, 1, NO); }
NSString *PreciseByteCount(long long bytes) { return ScaledByteCount(bytes, 2, YES); }

NSString *StorageVolumeTooltip(NSString *name, long long total, long long available, long long purgeable) {
    if (total < 0) total = 0;
    if (available < 0) available = 0;
    if (available > total) available = total;
    long long used = total - available;
    NSString *who = [name isKindOfClass:NSString.class] && name.length ? name : @"Volume";
    NSString *line = [NSString stringWithFormat:@"%@ — %@ of %@ used · %@ free",
                      who, PreciseByteCount(used), PreciseByteCount(total), PreciseByteCount(available)];
    if (purgeable > 0)
        line = [line stringByAppendingFormat:@" (%@ purgeable)", PreciseByteCount(purgeable)];
    return line;
}

double BatteryWatts(BatteryState b) {
    if (!b.valid || b.voltage_mV <= 0) return NAN;
    return (double)b.amperage_mA * (double)b.voltage_mV / 1e6;
}

NSString *FormatSignedWatts(double watts) {
    if (isnan(watts)) return nil;
    if (fabs(watts) < 0.05) return @"0 W";
    // Past 10 W the tenth is noise and costs the column room the charge time needs.
    NSString *fmt = fabs(watts) >= 10 ? @"%@%.0f W" : @"%@%.1f W";
    return [NSString stringWithFormat:fmt, watts > 0 ? @"+" : @"\u2212", fabs(watts)];
}

double BatteryWattHours(long mAh, long voltage_mV) {
    if (mAh <= 0 || voltage_mV <= 0 || mAh == LONG_MIN || voltage_mV == LONG_MIN) return NAN;
    return (double)mAh * (double)voltage_mV / 1e6;
}

NSString *FormatWattHours(double wh) {
    if (isnan(wh)) return nil;
    return wh < 100 ? [NSString stringWithFormat:@"%.1f Wh", wh] : [NSString stringWithFormat:@"%.0f Wh", wh];
}

PowerFlow PowerFlowFor(BatteryState b) {
    if (!b.valid) return PowerFlowUnknown;
    double w = BatteryWatts(b);
    if (!b.acConnected) return PowerFlowDischarging;
    if (!isnan(w) && w > 0.3) return PowerFlowCharging;
    BOOL inputKnown = b.systemPowerIn_mW != LONG_MIN && b.systemPowerIn_mW >= 0;
    if (inputKnown && b.systemPowerIn_mW < 1000) return PowerFlowPaused;   // charger recognised, nothing arriving
    if (!isnan(w) && w < -0.5) return PowerFlowPaused;                     // plugged in, battery still carrying load
    return PowerFlowHeld;
}

double PowerFlowIntensity(BatteryState b) {
    double w = BatteryWatts(b);
    if (isnan(w)) return 0;
    switch (PowerFlowFor(b)) {
        case PowerFlowCharging:    return MIN(1.0, MAX(0.0, w / 30.0));
        case PowerFlowDischarging: return MIN(1.0, MAX(0.0, -w / 25.0));
        default:                   return 0;
    }
}

int ChargeMinutesToTarget(BatteryState b, int targetPercent) {
    if (PowerFlowFor(b) != PowerFlowCharging) return -1;
    if (targetPercent <= b.percent) return -1;
    double watts = BatteryWatts(b);
    if (isnan(watts) || watts < 0.5) return -1;
    double fullWh = BatteryWattHours(b.rawMax_mAh, b.voltage_mV);
    if (isnan(fullWh) || fullWh <= 0) return -1;
    double needWh = ((double)(targetPercent - b.percent) / 100.0) * fullWh;
    if (needWh <= 0) return -1;
    return (int)lround(needWh / watts * 60.0);
}
