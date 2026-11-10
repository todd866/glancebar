#import "pure.h"
#import <math.h>
#import <limits.h>
#import <string.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <sys/stat.h>

static BOOL OfflineStat(NSString *path, NSString *root, struct stat *st) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath || !root.length) return NO;
    NSString *clean = path.stringByStandardizingPath;
    NSString *base = root.stringByStandardizingPath;
    if (![clean isEqual:path] || ![clean hasPrefix:[base stringByAppendingString:@"/"]]) return NO;
    if ([clean.pathComponents containsObject:@"CloudStorage"] || [clean.pathComponents containsObject:@"Mobile Documents"]) return NO;
    for (NSString *p = clean; p.length > 1; p = p.stringByDeletingLastPathComponent) {
        struct stat part;
        if (lstat(p.fileSystemRepresentation, &part) || S_ISLNK(part.st_mode)) return NO;
    }
    if (stat(clean.fileSystemRepresentation, st) || !S_ISREG(st->st_mode) || st->st_size <= 0 || (st->st_flags & SF_DATALESS)) return NO;
    return [NSFileManager.defaultManager isReadableFileAtPath:clean];
}

NSDictionary *OfflinePathsCoverage(NSArray *paths, NSString *musicRoot) {
    NSUInteger total = [paths isKindOfClass:NSArray.class] ? paths.count : 0, available = 0;
    for (id path in (total ? paths : @[])) { struct stat st; if (OfflineStat(path, musicRoot, &st)) available++; }
    BOOL ready = total > 0 && available == total;
    return @{@"total": @(total), @"available": @(available), @"ready": @(ready), @"paths": ready ? paths : @[]};
}

NSDictionary *OfflinePlaylistCoverage(NSDictionary *request, NSDictionary *manifest, NSString *musicRoot, BOOL verifyHash) {
    NSArray *wanted = [request[@"tracks"] isKindOfClass:NSArray.class] ? request[@"tracks"] : @[];
    NSDictionary *entry = nil;
    if ([manifest[@"schemaVersion"] isEqual:@1] && [manifest[@"playlists"] isKindOfClass:NSArray.class]) {
        for (id candidate in manifest[@"playlists"])
            if ([candidate isKindOfClass:NSDictionary.class] && [candidate[@"key"] isEqual:request[@"key"]]) { entry = candidate; break; }
    }
    NSMutableArray *paths = [NSMutableArray array];
    BOOL current = wanted.count && [entry[@"requestedTracks"] isEqual:wanted];
    NSArray *records = current && [entry[@"tracks"] isKindOfClass:NSArray.class] ? entry[@"tracks"] : @[];
    NSUInteger cursor = 0;
    BOOL inOrder = YES;
    for (id record in records) {
        if (![record isKindOfClass:NSDictionary.class]) { inOrder = NO; continue; }
        NSDictionary *identity = @{@"id": record[@"id"] ?: @"", @"title": record[@"title"] ?: @"",
            @"artist": record[@"artist"] ?: @"", @"album": record[@"album"] ?: @""};
        while (cursor < wanted.count && ![wanted[cursor] isEqual:identity]) cursor++;
        if (cursor == wanted.count) { inOrder = NO; continue; }
        cursor++;
        struct stat st;
        NSString *path = record[@"path"], *digest = record[@"sha256"];
        if (!OfflineStat(path, musicRoot, &st) || ![record[@"sizeBytes"] isKindOfClass:NSNumber.class] ||
            st.st_size != [record[@"sizeBytes"] longLongValue] || ![digest isKindOfClass:NSString.class] || digest.length != 64) continue;
        NSString *stamp = [NSString stringWithFormat:@"%lld", (long long)st.st_mtimespec.tv_sec * 1000000000LL + st.st_mtimespec.tv_nsec];
        if (![record[@"mtimeNs"] isEqual:stamp] || ![record[@"inode"] isEqual:[NSString stringWithFormat:@"%llu", (unsigned long long)st.st_ino]]) continue;
        if (verifyHash) {
            NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
            [stream open];
            CC_SHA256_CTX hash; CC_SHA256_Init(&hash);
            uint8_t buffer[65536], bytes[CC_SHA256_DIGEST_LENGTH];
            NSInteger n;
            while ((n = [stream read:buffer maxLength:sizeof(buffer)]) > 0) CC_SHA256_Update(&hash, buffer, (CC_LONG)n);
            [stream close];
            if (n < 0) continue;
            CC_SHA256_Final(bytes, &hash);
            NSMutableString *actual = [NSMutableString string];
            for (NSUInteger i = 0; i < sizeof(bytes); i++) [actual appendFormat:@"%02x", bytes[i]];
            struct stat after;
            if (![actual isEqual:digest] || !OfflineStat(path, musicRoot, &after) || after.st_ino != st.st_ino ||
                after.st_size != st.st_size || after.st_mtimespec.tv_sec != st.st_mtimespec.tv_sec ||
                after.st_mtimespec.tv_nsec != st.st_mtimespec.tv_nsec) continue;
        }
        [paths addObject:path];
    }
    BOOL complete = current && inOrder && wanted.count > 0 && paths.count == wanted.count;
    BOOL ready = current && inOrder && paths.count > 0;
    return @{@"total": @(wanted.count), @"available": @(paths.count), @"ready": @(ready),
            @"complete": @(complete), @"paths": paths};
}

BOOL MusicSilentQAEnabled(void) {
    const char *env = getenv("GLANCEBAR_SILENT_QA");
    if (env && env[0] && strcmp(env, "0") != 0) return YES;
    return [NSUserDefaults.standardUserDefaults boolForKey:@"musicSilentQA"];
}

float MusicPlayerOutputVolume(BOOL silentQA) { return silentQA ? 0.f : 1.f; }

BOOL MusicLibraryCannotFetch(BOOL networkOnline, BOOL metered, NSString *lastError, BOOL unmatched, BOOL overflow) {
    if (!networkOnline || metered || lastError.length || unmatched || overflow) return YES;
    return NO;
}

NSDictionary *OfflineMixTileState(NSDictionary *coverage, BOOL syncBusy, BOOL cannotFetch) {
    NSUInteger total = [coverage[@"total"] unsignedIntegerValue];
    NSUInteger available = [coverage[@"available"] unsignedIntegerValue];
    BOOL complete = [coverage[@"complete"] boolValue];
    NSString *countText = !total ? @"0 of 0 on this Mac"
        : [NSString stringWithFormat:@"%lu of %lu on this Mac", (unsigned long)available, (unsigned long)total];
    if (!total) {
        return @{@"state": @"empty", @"enabled": @NO, @"alpha": @0.4, @"tooltip": countText, @"partial": @NO};
    }
    if (complete) {
        return @{@"state": @"ready", @"enabled": @YES, @"alpha": @1.0, @"tooltip": countText, @"partial": @NO};
    }
    // Wait only while a fetch is actually running. With no sync in progress (it finished,
    // failed, or some tracks have no master to fetch) the tile plays what is on disk: a tile
    // must never sit dimmed forever.
    if (cannotFetch || !syncBusy) {
        BOOL enabled = available > 0;
        return @{@"state": enabled ? @"partial" : @"unavailable", @"enabled": @(enabled),
                 @"alpha": enabled ? @0.85 : @0.4, @"tooltip": countText, @"partial": @(enabled)};
    }
    NSString *tip = [NSString stringWithFormat:@"fetching %lu of %lu", (unsigned long)available, (unsigned long)total];
    return @{@"state": @"fetching", @"enabled": @NO, @"alpha": @0.4, @"tooltip": tip, @"partial": @NO};
}

static NSCalendar *MeteredCalendar(NSTimeZone *zone) {
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = zone ?: NSTimeZone.defaultTimeZone;
    cal.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    return cal;
}

static NSDate *MeteredMonthStart(NSCalendar *cal, NSInteger year, NSInteger month, NSInteger day) {
    NSDateComponents *c = [NSDateComponents new];
    c.calendar = cal; c.timeZone = cal.timeZone;
    c.year = year; c.month = month; c.day = 1;
    NSDate *first = [cal dateFromComponents:c];
    NSRange days = [cal rangeOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitMonth forDate:first];
    c.day = MIN(MAX(day, 1), (NSInteger)days.length);
    return [cal dateFromComponents:c];
}

NSDate *MeteredCycleStart(NSDate *now, int resetDay) { return MeteredCycleStartInZone(now, resetDay, nil); }
NSDate *MeteredCycleEnd(NSDate *now, int resetDay) { return MeteredCycleEndInZone(now, resetDay, nil); }

NSDate *MeteredCycleStartInZone(NSDate *now, int resetDay, NSTimeZone *zone) {
    if (!now) now = NSDate.date;
    NSCalendar *cal = MeteredCalendar(zone);
    NSDateComponents *parts = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth |
                                          NSCalendarUnitDay fromDate:now];
    NSDate *candidate = MeteredMonthStart(cal, parts.year, parts.month, resetDay);
    if ([candidate compare:now] == NSOrderedDescending) {
        NSDate *previous = [cal dateByAddingUnit:NSCalendarUnitMonth value:-1 toDate:candidate options:0];
        NSDateComponents *p = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:previous];
        candidate = MeteredMonthStart(cal, p.year, p.month, resetDay);
    }
    return candidate;
}

NSDate *MeteredCycleEndInZone(NSDate *now, int resetDay, NSTimeZone *zone) {
    NSDate *start = MeteredCycleStartInZone(now, resetDay, zone);
    NSCalendar *cal = MeteredCalendar(zone);
    NSDateComponents *p = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:start];
    NSInteger year = p.year, month = p.month + 1;
    if (month > 12) { month = 1; year++; }
    return MeteredMonthStart(cal, year, month, resetDay);
}

static uint64_t MeteredUInt64(id value) {
    return [value isKindOfClass:NSNumber.class] ? [value unsignedLongLongValue] : 0;
}

static NSArray<NSDictionary *> *MeteredSamples(NSDictionary *state) {
    NSArray *samples = [state[@"samples"] isKindOfClass:NSArray.class] ? state[@"samples"] : @[];
    return samples;
}

double MeteredRecentBytesPerSecond(NSDictionary *state, NSDate *now) {
    if (!state || ![state[@"onLink"] boolValue] || !now) return 0;
    double end = now.timeIntervalSince1970;
    NSMutableArray *samples = [NSMutableArray array];
    for (NSDictionary *sample in MeteredSamples(state)) {
        double time = [sample[@"time"] doubleValue];
        if (isfinite(time) && time >= end - 3600 && time <= end) [samples addObject:sample];
    }
    if (!isfinite(end) || samples.count < 2) return 0;
    NSDictionary *first = samples.firstObject, *last = samples.lastObject;
    double t0 = [first[@"time"] doubleValue], t1 = [last[@"time"] doubleValue];
    if (!isfinite(t0) || !isfinite(t1) || t1 <= t0 || end < t1 ||
        end - t1 > 3600.0 || t1 - t0 < 300.0) return 0;
    uint64_t b0 = MeteredUInt64(first[@"totalBytes"]), b1 = MeteredUInt64(last[@"totalBytes"]);
    return b1 >= b0 ? ((double)(b1 - b0) / (t1 - t0)) : 0;
}

NSDictionary *MeteredAccumulate(NSDictionary *previous, uint64_t inBytes,
                                 uint64_t outBytes, NSString *interfaceName,
                                 BOOL onLink, NSDate *now, int resetDay) {
    return MeteredAccumulateInZone(previous, inBytes, outBytes, interfaceName, onLink, now, resetDay, nil);
}

NSDictionary *MeteredAccumulateInZone(NSDictionary *previous, uint64_t inBytes,
                                       uint64_t outBytes, NSString *interfaceName,
                                       BOOL onLink, NSDate *now, int resetDay, NSTimeZone *zone) {
    if (!now) now = NSDate.date;
    NSDate *cycle = MeteredCycleStartInZone(now, resetDay, zone);
    uint64_t cycleEpoch = (uint64_t)llround(cycle.timeIntervalSince1970);
    double sampledEpoch = now.timeIntervalSince1970;
    NSString *iface = interfaceName ?: @"";
    uint64_t download = MeteredUInt64(previous[@"downloadBytes"]);
    uint64_t upload = MeteredUInt64(previous[@"uploadBytes"]);

    BOOL sameCycle = previous && MeteredUInt64(previous[@"cycleStart"]) == cycleEpoch;
    BOOL sameInterface = previous && [previous[@"interface"] isKindOfClass:NSString.class] &&
                         [previous[@"interface"] isEqualToString:iface];
    BOOL previousOn = previous && [previous[@"onLink"] boolValue];
    uint64_t oldIn = MeteredUInt64(previous[@"inBytes"]);
    uint64_t oldOut = MeteredUInt64(previous[@"outBytes"]);
    double oldAt = [previous[@"sampledAt"] isKindOfClass:NSNumber.class]
        ? [previous[@"sampledAt"] doubleValue] : 0;
    BOOL usableDelta = sameCycle && sameInterface && iface.length > 0 && previousOn && onLink &&
                       isfinite(oldAt) && oldAt > 0 && sampledEpoch >= oldAt &&
                       inBytes >= oldIn && outBytes >= oldOut;
    BOOL continuous = usableDelta && sampledEpoch - oldAt <= 3600.0;
    if (!sameCycle) {
        download = upload = 0;
    } else if (usableDelta) {
        uint64_t din = inBytes - oldIn;
        uint64_t dout = outBytes - oldOut;
        download += din;
        upload += dout;
    }
    NSArray *samples = @[];
    if (continuous) {
        NSMutableArray *kept = [MeteredSamples(previous) mutableCopy];
        [kept addObject:@{@"time": @(sampledEpoch), @"totalBytes": @(download + upload)}];
        while (kept.count && sampledEpoch - [kept.firstObject[@"time"] doubleValue] > 3600.0)
            [kept removeObjectAtIndex:0];
        samples = kept;
    } else if (onLink && iface.length > 0) {
        samples = @[@{@"time": @(sampledEpoch), @"totalBytes": @(download + upload)}];
    }

    return @{
        @"cycleStart": @(cycleEpoch),
        @"sampledAt": @(sampledEpoch),
        @"interface": iface,
        @"inBytes": @(inBytes),
        @"outBytes": @(outBytes),
        @"downloadBytes": @(download),
        @"uploadBytes": @(upload),
        @"onLink": @(onLink),
        @"bytesPerSecond": @(usableDelta && sampledEpoch > oldAt ?
                               ((double)(inBytes - oldIn) + (double)(outBytes - oldOut)) /
                               (sampledEpoch - oldAt) : 0),
        @"recentBytesPerSecond": @(MeteredRecentBytesPerSecond(@{ @"onLink": @(onLink), @"samples": samples }, now)),
        @"samples": samples
    };
}

NSData *ChromeCookieKey(NSString *password) {
    NSData *secret = [password dataUsingEncoding:NSUTF8StringEncoding];
    if (!secret.length) return nil;
    uint8_t key[kCCKeySizeAES128];
    if (CCKeyDerivationPBKDF(kCCPBKDF2, secret.bytes, secret.length, (const uint8_t *)"saltysalt", 9,
                             kCCPRFHmacAlgSHA1, 1003, key, sizeof(key)) != kCCSuccess) return nil;
    return [NSData dataWithBytes:key length:sizeof(key)];
}

NSString *ChromeCookieDecrypt(NSData *encrypted, NSData *key, NSString *hostKey) {
    if (encrypted.length < 3 + kCCBlockSizeAES128 || key.length != kCCKeySizeAES128 ||
        memcmp(encrypted.bytes, "v10", 3) != 0) return nil;
    NSMutableData *plain = [NSMutableData dataWithLength:encrypted.length];
    uint8_t iv[kCCBlockSizeAES128];
    memset(iv, ' ', sizeof(iv));
    size_t moved = 0;
    if (CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key.bytes, key.length, iv,
                (const uint8_t *)encrypted.bytes + 3, encrypted.length - 3,
                plain.mutableBytes, plain.length, &moved) != kCCSuccess) return nil;
    plain.length = moved;
    NSData *host = [hostKey dataUsingEncoding:NSUTF8StringEncoding];
    if (host && plain.length >= CC_SHA256_DIGEST_LENGTH) {
        uint8_t digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(host.bytes, (CC_LONG)host.length, digest);
        if (memcmp(plain.bytes, digest, sizeof(digest)) == 0)
            [plain replaceBytesInRange:NSMakeRange(0, sizeof(digest)) withBytes:NULL length:0];
    }
    return [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding];
}

NSDictionary *StarlinkUsageParse(NSData *json, NSDate *now) {
    if (!json.length) return nil;
    if (!now) now = NSDate.date;
    id root = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    id content = [root isKindOfClass:NSDictionary.class] ? root[@"content"] : nil;
    id cycles = [content isKindOfClass:NSDictionary.class] ? content[@"billingCyclesAnnotated"] : nil;
    if (![cycles isKindOfClass:NSArray.class]) return nil;
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    for (id cycle in cycles) {
        if (![cycle isKindOfClass:NSDictionary.class]) continue;
        NSDate *start = [cycle[@"startDate"] isKindOfClass:NSString.class] ? [iso dateFromString:cycle[@"startDate"]] : nil;
        NSDate *end = [cycle[@"endDate"] isKindOfClass:NSString.class] ? [iso dateFromString:cycle[@"endDate"]] : nil;
        id total = cycle[@"totalAmountGB"];
        if (!start || !end || ![total isKindOfClass:NSNumber.class] || !isfinite([total doubleValue]) ||
            [total doubleValue] < 0) continue;
        if ([start compare:now] != NSOrderedDescending && [now compare:end] == NSOrderedAscending)
            return @{ @"usedGB": total, @"cycleStart": @(start.timeIntervalSince1970),
                      @"cycleEnd": @(end.timeIntervalSince1970) };
    }
    return nil;
}

NSDictionary *MeteredAllowanceDatum(uint64_t remainingBytes, double rate,
                                     NSDate *now, NSDate *cycleEnd) {
    if (!now) now = NSDate.date;
    BOOL usable = isfinite(rate) && rate > 0 && cycleEnd &&
        [cycleEnd timeIntervalSinceDate:now] > 0;
    double seconds = usable ? (double)remainingBytes / rate : 0;
    BOOL lasts = usable && seconds < [cycleEnd timeIntervalSinceDate:now];
    NSString *resetText = @"resets unavailable";
    if (cycleEnd) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = NSTimeZone.defaultTimeZone;
        formatter.dateFormat = @"d MMM";
        resetText = [NSString stringWithFormat:@"resets %@", [formatter stringFromDate:cycleEnd]];
    }
    if (!lasts) {
        return @{ @"datum": resetText, @"urgency": @0, @"reset": resetText };
    }
    int minutes = (int)MAX(0, lround(seconds / 60.0));
    NSString *duration;
    if (seconds >= 48.0 * 3600.0) {
        int hours = (int)floor(seconds / 3600.0);
        duration = [NSString stringWithFormat:@"lasts %dd %dh", hours / 24, hours % 24];
    } else {
        duration = [NSString stringWithFormat:@"lasts %@", FmtDuration(minutes)];
    }
    int urgency = seconds < 2.0 * 3600.0 ? 2 : 1;
    return @{ @"datum": duration, @"urgency": @(urgency), @"reset": resetText };
}

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

// Quitting an app cuts the draw from D to D - A, stretching time to 20% by T * A / (D - A).
int BurnGainMinutes(int minutesTo20, double drawWatts, double appWatts) {
    if (minutesTo20 <= 0 || !isfinite(drawWatts) || !isfinite(appWatts) || appWatts <= 0 ||
        appWatts >= drawWatts) return -1;
    double gain = minutesTo20 * appWatts / (drawWatts - appWatts);
    if (!isfinite(gain) || gain < 30 || gain > INT_MAX) return -1;
    return (int)lround(gain);
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
        if (mins > 0) d[@"windowSeconds"] = @(mins * 60.0);
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
        if (mins > 0) d[@"windowSeconds"] = @(mins * 60.0);
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

static NSDictionary *CursorWindow(NSString *name, NSString *pool, double remainingFrac, double resets) {
    remainingFrac = remainingFrac < 0 ? 0 : remainingFrac > 1 ? 1 : remainingFrac;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"window"] = name;
    if (pool.length) d[@"pool"] = pool;
    d[@"remainingFraction"] = @(remainingFrac);
    if (resets > 0) d[@"resetsAt"] = @(resets);
    return d;
}

static NSNumber *CursorFiniteNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    // NSNumber also represents JSON booleans. Treating false as 0% used would make a
    // malformed quota look healthy, so only accept actual numeric values.
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
    double n = [value doubleValue];
    return isfinite(n) ? (NSNumber *)value : nil;
}

static NSArray<NSString *> *CursorAutoBucketModels(NSDictionary *usage) {
    NSArray *raw = [usage[@"autoBucketModels"] isKindOfClass:NSArray.class] ? usage[@"autoBucketModels"] : nil;
    if (!raw.count) return nil;
    NSMutableArray *models = [NSMutableArray array];
    for (id value in raw) {
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *model = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (model.length && ![models containsObject:model]) [models addObject:model];
    }
    return models.count ? models : nil;
}

// GetCurrentPeriodUsage has changed shape before: early bodies carried remaining/limit;
// current ones (seen 2026-10) split the allowance into an API pool for third-party models and
// a Cursor pool (the historical wire name is autoPercentUsed), each with its own
// percentage. totalPercentUsed blends the two and hides a nearly spent API pool, so the
// pools win over it whenever either valid split field is present.
static NSArray<NSDictionary *> *CursorPlanWindowsFiltered(NSDictionary *usage, double nowEpoch, BOOL elapsedOnly) {
    NSDictionary *plan = [usage[@"planUsage"] isKindOfClass:NSDictionary.class] ? usage[@"planUsage"] : nil;
    if (!plan) return @[];
    double resets = CursorEpochSeconds(usage[@"billingCycleEnd"]);
    if (elapsedOnly) {
        if (!(resets > 0 && resets <= nowEpoch)) return @[];
    } else if (resets > 0 && resets <= nowEpoch) {
        return @[];
    }

    NSNumber *api = CursorFiniteNumber(plan[@"apiPercentUsed"]);
    NSNumber *autoPool = CursorFiniteNumber(plan[@"autoPercentUsed"]);
    BOOL splitFieldsPresent = plan[@"apiPercentUsed"] != nil || plan[@"autoPercentUsed"] != nil;
    if (splitFieldsPresent) {
        NSMutableArray *pools = [NSMutableArray array];
        if (api) [pools addObject:CursorWindow(@"API models", @"api", 1.0 - api.doubleValue / 100.0, resets)];
        if (autoPool) {
            NSMutableDictionary *cursor = [CursorWindow(@"Cursor models", @"cursor", 1.0 - autoPool.doubleValue / 100.0, resets) mutableCopy];
            NSArray *models = CursorAutoBucketModels(usage);
            if (models) cursor[@"models"] = models;
            [pools addObject:cursor];
        }
        return pools;
    }
    NSNumber *remaining = CursorFiniteNumber(plan[@"remaining"]);
    NSNumber *limit = CursorFiniteNumber(plan[@"limit"]);
    if (remaining && limit && limit.doubleValue > 0)
        return @[CursorWindow(@"billing period", nil, remaining.doubleValue / limit.doubleValue, resets)];
    NSNumber *totalPercent = CursorFiniteNumber(plan[@"totalPercentUsed"]);
    if (totalPercent)
        return @[CursorWindow(@"billing period", nil, 1.0 - totalPercent.doubleValue / 100.0, resets)];
    NSNumber *includedSpend = CursorFiniteNumber(plan[@"includedSpend"]);
    if (includedSpend && limit && limit.doubleValue > 0)
        return @[CursorWindow(@"billing period", nil, 1.0 - includedSpend.doubleValue / limit.doubleValue, resets)];
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

// A plan window spans the billing cycle; its length lets the gauge show pace.
static NSArray<NSDictionary *> *CursorWithCycleLength(NSArray<NSDictionary *> *windows, NSDictionary *usage) {
    double start = CursorEpochSeconds(usage[@"billingCycleStart"]);
    double end = CursorEpochSeconds(usage[@"billingCycleEnd"]);
    if (!(start > 0 && end > start) || !windows.count) return windows;
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *w in windows) {
        NSMutableDictionary *d = [w mutableCopy];
        d[@"windowSeconds"] = @(end - start);
        [out addObject:d];
    }
    return out;
}

NSArray<NSDictionary *> *CursorLimitWindows(NSDictionary *usage, double nowEpoch) {
    if (![usage isKindOfClass:NSDictionary.class]) return @[];
    NSArray<NSDictionary *> *plan = CursorWithCycleLength(CursorPlanWindowsFiltered(usage, nowEpoch, NO), usage);
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
    BOOL systemHeader = NO, activeHeader = NO, sleepTimer = NO;
    for (NSString *line in [pmsetOutput componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trimmed isEqualToString:@"System-wide power settings:"]) systemHeader = YES;
        if (systemHeader && [trimmed isEqualToString:@"Currently in use:"]) activeHeader = YES;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSString *s in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
            if (s.length) [parts addObject:s];
        if (parts.count && [parts[0] isEqualToString:@"SleepDisabled"]) {
            if (parts.count != 2) return nil;
            NSScanner *scanner = [NSScanner scannerWithString:parts[1]];
            long long value;
            if (![scanner scanLongLong:&value] || !scanner.isAtEnd) return nil;
            return @(value != 0);
        }
        if (activeHeader && parts.count >= 2 && [parts[0] isEqualToString:@"sleep"]) {
            NSScanner *scanner = [NSScanner scannerWithString:parts[1]];
            long long value;
            sleepTimer = [scanner scanLongLong:&value] && scanner.isAtEnd && value >= 0;
        }
    }
    // pmset only prints SleepDisabled when the system preference has been set.
    // A normal settings report without it means the default (sleep enabled).
    // Require a recognizable report so errors/truncated output remain unknown.
    return systemHeader && activeHeader && sleepTimer ? @NO : nil;
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

static NSDictionary *PlayerOutputDevice(NSArray<NSDictionary *> *devices, NSString *uid) {
    if (![devices isKindOfClass:NSArray.class] || ![uid isKindOfClass:NSString.class] || !uid.length) return nil;
    for (id row in devices) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        if ([row[@"uid"] isEqual:uid] && AudioChannels(row) > 0) return row;
    }
    return nil;
}

NSDictionary *PlayerOutputChoice(NSString *chosenUID, NSString *chosenName,
                                   NSArray<NSDictionary *> *devices, NSString *defaultUID) {
    if (![devices isKindOfClass:NSArray.class]) devices = @[];
    if (![chosenUID isKindOfClass:NSString.class]) chosenUID = @"";
    if (![defaultUID isKindOfClass:NSString.class]) defaultUID = @"";
    NSDictionary *defaultDevice = PlayerOutputDevice(devices, defaultUID);
    NSString *defaultName = defaultDevice[@"name"] ?: @"No output device";
    if (!chosenUID.length) {
        return @{@"choiceUID": @"", @"effectiveUID": defaultUID ?: @"", @"system": @YES,
                 @"device": defaultDevice ?: @{}, @"name": defaultName, @"note": @""};
    }
    NSDictionary *chosen = PlayerOutputDevice(devices, chosenUID);
    if (chosen) {
        return @{@"choiceUID": chosenUID, @"effectiveUID": chosenUID, @"system": @NO,
                 @"device": chosen, @"name": chosen[@"name"] ?: @"Output", @"note": @""};
    }
    if (![chosenName isKindOfClass:NSString.class]) chosenName = @"";
    NSString *note = chosenName.length ? [NSString stringWithFormat:@"%@ is not connected; using System.", chosenName]
                                       : @"Selected output is not connected; using System.";
    return @{@"choiceUID": chosenUID, @"effectiveUID": defaultUID ?: @"", @"system": @YES,
             @"device": defaultDevice ?: @{}, @"name": defaultName, @"note": note};
}

NSArray<NSDictionary *> *PlayerOutputMenuChoices(NSArray<NSDictionary *> *devices,
                                                 NSString *defaultUID) {
    NSMutableArray *out = [NSMutableArray array];
    NSDictionary *defaultDevice = PlayerOutputDevice(devices, defaultUID);
    NSString *detail = defaultDevice[@"name"] ?: @"";
    NSString *systemTitle = detail.length ? [NSString stringWithFormat:@"System (%@)", detail] : @"System";
    [out addObject:@{@"uid": @"", @"name": systemTitle, @"system": @YES}];
    for (NSDictionary *device in AudioOutputMenuDevices(devices, defaultUID))
        [out addObject:@{@"uid": device[@"uid"] ?: @"", @"name": device[@"name"] ?: @"Output", @"system": @NO}];
    return out;
}

NSString *PlayerOutputCycleNext(NSArray<NSDictionary *> *choices, NSString *currentUID) {
    if (![choices isKindOfClass:NSArray.class] || choices.count < 2) return nil;
    if (![currentUID isKindOfClass:NSString.class]) currentUID = @"";
    NSMutableArray<NSString *> *uids = [NSMutableArray array];
    for (id row in choices) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        id uid = row[@"uid"];
        if ([uid isKindOfClass:NSString.class]) [uids addObject:uid];
        else [uids addObject:@""];
    }
    if (uids.count < 2) return nil;
    NSUInteger index = [uids indexOfObject:currentUID];
    if (index == NSNotFound) index = [currentUID length] ? NSNotFound : 0;
    if (index == NSNotFound) return uids[0];
    return uids[(index + 1) % uids.count];
}

static NSString *ExternalPlaybackString(NSDictionary *userInfo, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = userInfo[key];
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length]) return value;
    }
    return @"";
}

static BOOL ExternalPlaybackPlaying(NSString *state) {
    if (!state.length) return NO;
    NSString *s = state.lowercaseString;
    return [s isEqual:@"playing"] || [s isEqual:@"play"] || [s containsString:@"playing"];
}

NSDictionary *ParseExternalPlayback(NSDictionary *userInfo, NSString *source) {
    NSMutableDictionary *out = [@{@"source": @"", @"title": @"", @"artist": @"", @"playing": @NO, @"valid": @NO} mutableCopy];
    if (![userInfo isKindOfClass:NSDictionary.class]) return out;
    if ([source isEqual:@"music"] || [source isEqual:@"spotify"]) out[@"source"] = source;
    NSString *state = ExternalPlaybackString(userInfo, @[@"Player State", @"PlayerState", @"PlaybackState"]);
    NSString *title = ExternalPlaybackString(userInfo, @[@"Name", @"Track Name", @"Album"]);
    NSString *artist = ExternalPlaybackString(userInfo, @[@"Artist", @"Artist Name"]);
    BOOL playing = ExternalPlaybackPlaying(state);
    if (!title.length && !artist.length && !state.length) return out;
    out[@"title"] = title;
    out[@"artist"] = artist;
    out[@"playing"] = @(playing);
    out[@"valid"] = @(playing && (title.length || artist.length));
    return out;
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
    NSNumber *volume = YouTubeStatusNumber(fields, 7);
    // JavaScript is refused only after a music tab was found and execute javascript ran.
    // Automation is refused before any tab can be seen. Either way the page told us nothing.
    if ([denied isEqual:@"automation"]) {
        tab = NO; playing = [NSNull null]; title = @""; artist = @""; count = 0;
        elapsed = nil; duration = nil; volume = nil;
    } else if ([denied isEqual:@"javascript"]) {
        tab = YES; playing = [NSNull null]; title = @""; artist = @""; count = 0;
        elapsed = nil; duration = nil; volume = nil;
    }
    NSMutableDictionary *status = [@{@"tab": @(tab), @"playing": playing, @"title": title,
                                     @"artist": artist, @"count": @(count), @"denied": denied} mutableCopy];
    if (elapsed) status[@"elapsed"] = elapsed;
    if (duration) status[@"duration"] = duration;
    if (volume) {
        double level = volume.doubleValue;
        if (level < 0) level = 0;
        if (level > 1) level = 1;
        status[@"volume"] = @(level);
    }
    return status;
}

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

const double kMusicNextTapWindowSec = 0.25;
const double kMusicNextTimerSlopSec = 0.05;
const double kMusicBlendFullSec = 6.0;
const double kMusicBlendMinSec = 1.0;

static double MusicNextWindow(double windowSec) {
    if (!isfinite(windowSec) || windowSec < 0) return kMusicNextTapWindowSec;
    return windowSec;
}

MusicNextTap ClassifyMusicNext(double *armedAt, double now, double windowSec,
                               BOOL timerFired, BOOL blending) {
    double armed = (armedAt && isfinite(*armedAt) && *armedAt > 0) ? *armedAt : 0;
    // A fade is already running: this press cuts it. The window timer must not
    // start a second fade on top, so a late fire is ignored once the arm is cleared.
    if (blending && !timerFired) {
        if (armedAt) *armedAt = 0;
        return MusicNextTapCut;
    }
    if (timerFired) {
        if (!(armed > 0) || !isfinite(now)) return MusicNextTapNone;
        double window = MusicNextWindow(windowSec);
        // 1e-4 covers the rounding of (armed+window) - now against the slop.
        if ((armed + window) - now > kMusicNextTimerSlopSec + 1e-4) return MusicNextTapNone;
        if (armedAt) *armedAt = 0;
        if (blending) return MusicNextTapNone;
        return MusicNextTapBlend;
    }
    if (!isfinite(now)) return MusicNextTapNone;
    double window = MusicNextWindow(windowSec);
    // Inside the window, including the exact edge. A timestamp that went backwards
    // is a new first press, not a double tap.
    if (armed > 0 && now >= armed && now - armed <= window) {
        if (armedAt) *armedAt = 0;
        return MusicNextTapCut;
    }
    if (!armedAt) return MusicNextTapNone;
    *armedAt = now;
    return MusicNextTapWait;
}

MusicBlendGain MusicBlendGainAt(double t) {
    MusicBlendGain g = {1, 0};
    if (!isfinite(t) || t <= 0) return g;
    if (t >= 1) {
        g.outgoing = 0;
        g.incoming = 1;
        return g;
    }
    g.outgoing = cos(t * (M_PI / 2.0));
    g.incoming = sin(t * (M_PI / 2.0));
    return g;
}

double MusicBlendSeconds(double remainingSec, double fullSec, double minSec) {
    if (!isfinite(fullSec) || fullSec < 0) fullSec = kMusicBlendFullSec;
    if (!isfinite(minSec) || minSec < 0) minSec = kMusicBlendMinSec;
    if (minSec > fullSec) minSec = fullSec;
    if (!isfinite(remainingSec) || remainingSec < 0) return fullSec;
    if (remainingSec >= fullSec) return fullSec;
    if (remainingSec < minSec) return minSec;
    return remainingSec;
}

int MusicVolumeCents(double volume) {
    if (!isfinite(volume) || volume <= 0) return 0;
    long rounded = llround(volume * 100.0);
    if (rounded < 0) return 0;
    if (rounded > 100) return 100;
    return (int)rounded;
}

BOOL MusicBlendCutOwesNext(int phase, BOOL skipSent) {
    (void)phase;
    return !skipSent;
}

BOOL VolumeScriptShouldApply(uint64_t applyGeneration, uint64_t latestGeneration) {
    return applyGeneration == latestGeneration;
}

static int ClampMusicVolume(int volume) {
    if (volume < 0) return 0;
    if (volume > 100) return 100;
    return volume;
}

BOOL MusicRestoredVolumeMatches(BOOL readOK, int readVolume, int original) {
    if (!readOK) return NO;
    return ClampMusicVolume(readVolume) == ClampMusicVolume(original);
}

BOOL YouTubeRestoredVolumeMatches(BOOL readOK, double readVolume, double original) {
    if (!readOK || !isfinite(readVolume) || !isfinite(original)) return NO;
    return MusicVolumeCents(readVolume) == MusicVolumeCents(original);
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

static NSNumber *AppleMusicMilliseconds(NSArray<NSString *> *fields, NSUInteger index) {
    NSString *field = YouTubeStatusField(fields, index);
    if (!field.length) return nil;
    NSScanner *scanner = [NSScanner scannerWithString:field];
    long long value = 0;
    if (![scanner scanLongLong:&value] || !scanner.isAtEnd || value < 0) return nil;
    return @(value / 1000.0);
}

NSDictionary *ParseAppleMusicStatus(NSString *output) {
    NSString *out = [output isKindOfClass:NSString.class] ? output : @"";
    NSString *trimmed = [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *fields = [trimmed containsString:YouTubeStatusSeparator]
        ? [trimmed componentsSeparatedByString:YouTubeStatusSeparator] : @[];
    NSString *state = YouTubeStatusField(fields, 0).lowercaseString;
    NSString *title = YouTubeStatusField(fields, 2);
    BOOL playing = [state isEqual:@"playing"];
    BOOL loaded = (playing || [state isEqual:@"paused"]) && title.length > 0;
    NSMutableDictionary *status = [@{
        @"state": state, @"loaded": @(loaded), @"playing": @(playing),
        @"shuffle": @([YouTubeStatusField(fields, 1) isEqual:@"true"]),
        @"title": title, @"artist": YouTubeStatusField(fields, 3), @"album": YouTubeStatusField(fields, 4),
        @"favorited": @([YouTubeStatusField(fields, 7) isEqual:@"true"]),
        @"trackID": YouTubeStatusField(fields, 8), @"playlist": YouTubeStatusField(fields, 9),
    } mutableCopy];
    NSNumber *duration = AppleMusicMilliseconds(fields, 5);
    NSNumber *elapsed = AppleMusicMilliseconds(fields, 6);
    if (duration && duration.doubleValue > 0) status[@"duration"] = duration;
    if (elapsed) status[@"elapsed"] = elapsed;
    return status;
}

NSString *AppleScriptQuoted(NSString *text) {
    NSString *s = [text isKindOfClass:NSString.class] ? text : @"";
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"\"%@\"", s];
}

NSString *FormatTrackClock(double seconds, double duration) {
    if (!isfinite(duration) || duration <= 0 || !isfinite(seconds)) return nil;
    if (seconds < 0) seconds = 0;
    if (seconds > duration) seconds = duration;
    return FormatClockPart(seconds, duration >= 3600.0);
}

BOOL YieldLocalMusic(BOOL localMode, BOOL networkOnline, BOOL playing) {
    (void)localMode;
    (void)networkOnline;
    (void)playing;
    return NO;
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

static BOOL GlanceVolumeFlag(NSDictionary *volume, NSString *key) {
    id value = volume[key];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}

static NSString *GlanceString(NSDictionary *volume, NSString *key) {
    id value = volume[key];
    return [value isKindOfClass:NSString.class] && [(NSString *)value length] ? value : nil;
}

static BOOL GlanceHasBytes(NSDictionary *volume, NSString *key) {
    return [volume[key] isKindOfClass:NSNumber.class];
}

static long long GlanceBytes(NSDictionary *volume, NSString *key) {
    return [volume[key] longLongValue];
}

static NSArray<NSString *> *GlanceCleanNames(NSArray<NSString *> *names) {
    if (![names isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (id name in names)
        if ([name isKindOfClass:NSString.class] && [(NSString *)name length]) [clean addObject:name];
    return clean;
}

NSString *VolumeContainerID(NSString *bsdName) {
    if (![bsdName isKindOfClass:NSString.class] || !bsdName.length) return nil;
    NSString *name = [bsdName hasPrefix:@"/dev/"] ? [bsdName substringFromIndex:5] : bsdName;
    if (![name hasPrefix:@"disk"] || name.length < 5) return nil;
    NSUInteger i = 4;
    if ([name characterAtIndex:i] < '0' || [name characterAtIndex:i] > '9') return nil;
    while (i < name.length) {
        unichar c = [name characterAtIndex:i];
        if (c < '0' || c > '9') break;
        i++;
    }
    if (i < name.length && [name characterAtIndex:i] != 's') return nil;
    return [name substringToIndex:i];
}

NSString *GlanceVolumeJoinedName(NSArray<NSString *> *names) {
    NSArray<NSString *> *clean = GlanceCleanNames(names);
    return clean.count ? [clean componentsJoinedByString:@" · "] : nil;
}

NSString *GlanceVolumeCompactName(NSArray<NSString *> *names) {
    NSArray<NSString *> *clean = GlanceCleanNames(names);
    if (!clean.count) return nil;
    if (clean.count == 1) return clean[0];
    return [NSString stringWithFormat:@"%@ +%lu", clean[0], (unsigned long)(clean.count - 1)];
}

static BOOL GlanceVolumeSkippedPath(NSDictionary *volume) {
    NSString *path = GlanceString(volume, @"path");
    return [path isEqualToString:@"/"] || [path isEqualToString:@"/System"] ||
        [path hasPrefix:@"/System/Volumes"];
}

// A glance row: named, sized, local, and not the boot disk, an internal disk,
// a system volume, or a disk image.
static BOOL GlanceExternalCandidate(NSDictionary *volume) {
    if (GlanceVolumeSkippedPath(volume)) return NO;
    if (GlanceVolumeFlag(volume, @"boot") || GlanceVolumeFlag(volume, @"internal") ||
        GlanceVolumeFlag(volume, @"diskImage"))
        return NO;
    if (!GlanceVolumeFlag(volume, @"local")) return NO;
    if (!GlanceHasBytes(volume, @"totalBytes") || GlanceBytes(volume, @"totalBytes") <= 0) return NO;
    return GlanceString(volume, @"name") != nil;
}

static BOOL GlanceDiskImageOnADisk(NSDictionary *volume) {
    if (!GlanceVolumeFlag(volume, @"diskImage") || !GlanceVolumeFlag(volume, @"local")) return NO;
    if (GlanceVolumeFlag(volume, @"boot") || GlanceVolumeFlag(volume, @"internal")) return NO;
    if (GlanceVolumeSkippedPath(volume)) return NO;
    return GlanceString(volume, @"name") != nil;
}

static BOOL GlanceBackingOnVolume(NSString *volumePath, NSString *backingPath) {
    if (!volumePath.length || !backingPath.length) return NO;
    NSString *prefix = [volumePath hasSuffix:@"/"] ? volumePath : [volumePath stringByAppendingString:@"/"];
    return [backingPath hasPrefix:prefix];
}

static NSString *GlanceHostPath(NSString *backingPath, NSArray *volumes) {
    NSString *best = nil;
    for (id row in volumes) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *path = GlanceString(row, @"path");
        if (!GlanceBackingOnVolume(path, backingPath)) continue;
        if (!best || path.length > best.length) best = path;
    }
    return best;
}

static NSInteger GlanceRowIndexForPath(NSArray<NSDictionary *> *rows, NSString *path) {
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSDictionary *row = rows[i];
        if ([GlanceString(row, @"path") isEqualToString:path]) return (NSInteger)i;
        id paths = row[@"paths"];
        if ([paths isKindOfClass:NSArray.class] && [paths containsObject:path]) return (NSInteger)i;
    }
    return NSNotFound;
}

static NSDictionary *GlanceRowAddingHosted(NSDictionary *row, NSString *imageName) {
    if (!imageName.length) return row;
    NSMutableArray *hosted = [NSMutableArray array];
    if ([row[@"hosted"] isKindOfClass:NSArray.class]) {
        for (id name in row[@"hosted"])
            if ([name isKindOfClass:NSString.class] && [(NSString *)name length]) [hosted addObject:name];
    }
    if (![hosted containsObject:imageName]) [hosted addObject:imageName];
    NSMutableDictionary *copy = [row mutableCopy];
    copy[@"hosted"] = hosted;
    return copy;
}

// One physical disk. Shared APFS space is counted once; independent partitions
// (different totals, no container size) add up instead of dropping a partition.
static NSDictionary *GlanceAggregateVolumes(NSArray<NSDictionary *> *members, NSString *container) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    long long usedSum = 0;
    BOOL allUsed = YES;
    long long totalSum = 0, firstTotal = 0, freeSum = 0, firstFree = 0;
    BOOL anyTotal = NO, sameTotal = YES, anyFree = NO, sameFree = YES;
    long long containerBytes = 0, containerFree = 0, largestFree = 0;
    BOOL haveContainerFree = NO;
    for (NSDictionary *member in members) {
        NSString *name = GlanceString(member, @"name");
        if (name) [names addObject:name];
        NSString *path = GlanceString(member, @"path");
        if (path) [paths addObject:path];
        if (GlanceHasBytes(member, @"usedBytes") && GlanceBytes(member, @"usedBytes") >= 0)
            usedSum += GlanceBytes(member, @"usedBytes");
        else allUsed = NO;
        if (GlanceHasBytes(member, @"totalBytes")) {
            long long total = GlanceBytes(member, @"totalBytes");
            if (!anyTotal) { firstTotal = total; anyTotal = YES; }
            else if (total != firstTotal) sameTotal = NO;
            if (total > 0) totalSum += total;
        }
        if (GlanceHasBytes(member, @"freeBytes")) {
            long long free = MAX(0LL, GlanceBytes(member, @"freeBytes"));
            if (!anyFree) { firstFree = free; anyFree = YES; }
            else if (free != firstFree) sameFree = NO;
            freeSum += free;
            if (free > largestFree) largestFree = free;
        }
        if (GlanceHasBytes(member, @"containerBytes"))
            containerBytes = MAX(containerBytes, GlanceBytes(member, @"containerBytes"));
        if (!haveContainerFree && GlanceHasBytes(member, @"containerFreeBytes")) {
            containerFree = MAX(0LL, GlanceBytes(member, @"containerFreeBytes"));
            haveContainerFree = YES;
        }
    }
    BOOL shared = containerBytes > 0 || (anyTotal && sameTotal);
    long long total = containerBytes > 0 ? containerBytes : (shared ? firstTotal : totalSum);
    long long free = haveContainerFree && shared ? containerFree
        : (shared && sameFree) ? firstFree
        : shared ? largestFree
        : freeSum;
    if (free < 0) free = 0;
    if (shared && total > 0 && free > total) free = total;
    long long used;
    if (allUsed) used = usedSum;
    else if (shared) used = MAX(0LL, total - free);
    else {
        used = 0;
        for (NSDictionary *member in members) {
            long long partTotal = GlanceHasBytes(member, @"totalBytes") ? GlanceBytes(member, @"totalBytes") : 0;
            long long partFree = GlanceHasBytes(member, @"freeBytes") ? GlanceBytes(member, @"freeBytes") : 0;
            if (partFree < 0) partFree = 0;
            if (partFree > partTotal) partFree = partTotal;
            used += MAX(0LL, partTotal - partFree);
        }
    }
    return @{
        @"name": [names componentsJoinedByString:@" · "] ?: @"",
        @"names": names,
        @"path": paths.firstObject ?: @"",
        @"paths": paths,
        @"container": container ?: @"",
        @"totalBytes": @(total),
        @"freeBytes": @(free),
        @"usedBytes": @(MAX(0LL, used)),
        @"local": @YES,
        @"boot": @NO,
        @"internal": @NO,
        @"diskImage": @NO,
        @"grouped": @YES,
    };
}

double GlanceExternalUsedFraction(NSDictionary *row) {
    if (![row isKindOfClass:NSDictionary.class]) return 0;
    long long total = GlanceHasBytes(row, @"totalBytes") ? GlanceBytes(row, @"totalBytes") : 0;
    if (total <= 0) return 0;
    if (GlanceVolumeFlag(row, @"grouped") && GlanceHasBytes(row, @"usedBytes")) {
        long long used = GlanceBytes(row, @"usedBytes");
        if (used < 0) used = 0;
        return MIN(1.0, (double)used / (double)total);
    }
    long long free = GlanceHasBytes(row, @"freeBytes") ? GlanceBytes(row, @"freeBytes") : 0;
    if (free < 0) free = 0;
    if (free > total) free = total;
    return (double)(total - free) / (double)total;
}

NSString *GlanceExternalTooltip(NSDictionary *row) {
    if (![row isKindOfClass:NSDictionary.class]) return nil;
    long long total = GlanceHasBytes(row, @"totalBytes") ? MAX(0LL, GlanceBytes(row, @"totalBytes")) : 0;
    long long free = GlanceHasBytes(row, @"freeBytes") ? GlanceBytes(row, @"freeBytes") : 0;
    if (free < 0) free = 0;
    if (total > 0 && free > total) free = total;
    long long used = GlanceVolumeFlag(row, @"grouped") && GlanceHasBytes(row, @"usedBytes")
        ? MAX(0LL, GlanceBytes(row, @"usedBytes")) : MAX(0LL, total - free);
    NSString *name = GlanceString(row, @"name") ?: @"Volume";
    NSString *line = [NSString stringWithFormat:@"%@ — %@ of %@ used · %@ free",
                      name, PreciseByteCount(used), PreciseByteCount(total), PreciseByteCount(free)];
    NSMutableArray<NSString *> *hosted = [NSMutableArray array];
    if ([row[@"hosted"] isKindOfClass:NSArray.class]) {
        for (id image in row[@"hosted"])
            if ([image isKindOfClass:NSString.class] && [(NSString *)image length]) [hosted addObject:image];
    }
    if (hosted.count == 1)
        line = [line stringByAppendingFormat:@"\nDisk image: %@", hosted[0]];
    else if (hosted.count > 1)
        line = [line stringByAppendingFormat:@"\nDisk images: %@", [hosted componentsJoinedByString:@" · "]];
    return line;
}

NSArray<NSDictionary *> *GlanceExternalVolumes(NSArray<NSDictionary *> *volumes) {
    if (![volumes isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *images = [NSMutableArray array];
    for (id row in volumes) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *volume = row;
        if (GlanceExternalCandidate(volume)) [candidates addObject:volume];
        else if (GlanceDiskImageOnADisk(volume)) [images addObject:volume];
    }
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *groups = [NSMutableDictionary dictionary];
    NSUInteger alone = 0;
    for (NSDictionary *volume in candidates) {
        NSString *container = GlanceString(volume, @"container");
        NSString *key = container ?: [NSString stringWithFormat:@"\n%lu", (unsigned long)alone++];
        if (!groups[key]) {
            groups[key] = [NSMutableArray array];
            [order addObject:key];
        }
        [groups[key] addObject:volume];
    }
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSString *key in order) {
        NSArray<NSDictionary *> *members = groups[key];
        if (members.count == 1) [out addObject:members[0]];
        else [out addObject:GlanceAggregateVolumes(members, [key hasPrefix:@"\n"] ? nil : key)];
    }
    for (NSDictionary *image in images) {
        NSString *host = GlanceHostPath(GlanceString(image, @"backingPath"), volumes);
        NSInteger index = GlanceRowIndexForPath(out, host);
        if (index == NSNotFound) continue;
        out[(NSUInteger)index] = GlanceRowAddingHosted(out[(NSUInteger)index], GlanceString(image, @"name"));
    }
    return out;
}

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
    if (!isnan(w) && w < -0.5) return inputKnown ? PowerFlowShort          // arriving, but less than the load
                                                 : PowerFlowPaused;        // plugged in, battery still carrying load
    return PowerFlowHeld;
}

BOOL ChargerFallsShort(BatteryState b) {
    double w = BatteryWatts(b);
    return b.valid && b.acConnected && b.systemPowerIn_mW != LONG_MIN && b.systemPowerIn_mW >= 0 &&
        !isnan(w) && w < -0.5;
}

double PowerFlowIntensity(BatteryState b) {
    double w = BatteryWatts(b);
    if (isnan(w)) return 0;
    switch (PowerFlowFor(b)) {
        case PowerFlowCharging:    return MIN(1.0, MAX(0.0, w / 30.0));
        case PowerFlowDischarging:
        case PowerFlowShort:       return MIN(1.0, MAX(0.0, -w / 25.0));
        default:                   return 0;
    }
}

int ChargeMinutesToTarget(BatteryState b, int targetPercent) {
    if (PowerFlowFor(b) != PowerFlowCharging) return -1;
    if (targetPercent <= b.percent) return -1;
    if (targetPercent == 100) return b.isCharging && b.minutesToFull > 0 && b.minutesToFull <= 1440 ? (int)b.minutesToFull : -1;
    double watts = BatteryWatts(b);
    if (isnan(watts) || watts < 0.5) return -1;
    double fullWh = BatteryWattHours(b.rawMax_mAh, b.voltage_mV);
    if (isnan(fullWh) || fullWh <= 0) return -1;
    double needWh = ((double)(targetPercent - b.percent) / 100.0) * fullWh;
    if (needWh <= 0) return -1;
    return (int)lround(needWh / watts * 60.0);
}

double QuotaWindowSeconds(NSDictionary *window) {
    if (![window isKindOfClass:NSDictionary.class]) return 0;
    NSNumber *explicitLength = [window[@"windowSeconds"] isKindOfClass:NSNumber.class] ? window[@"windowSeconds"] : nil;
    if (explicitLength.doubleValue > 0) return explicitLength.doubleValue;
    NSString *label = [window[@"window"] isKindOfClass:NSString.class] ? window[@"window"] : @"";
    if ([label isEqualToString:@"weekly"] || [label hasPrefix:@"weekly "]) return 7 * 86400.0;
    if ([label isEqualToString:@"5-hour"]) return 5 * 3600.0;
    return 0;
}

static NSArray<NSDictionary *> *SortedBurnRows(NSArray<NSDictionary *> *rows);
NSArray<NSDictionary *> *BurnRows(NSDictionary<NSNumber *, NSNumber *> *prev,
                                  NSDictionary<NSNumber *, NSNumber *> *cur,
                                  NSDictionary<NSNumber *, NSNumber *> *baseline,
                                  double dtSeconds, NSString *(^groupFor)(pid_t pid)) {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    for (NSNumber *pid in cur) {
        double now = cur[pid].doubleValue;
        NSNumber *before = prev[pid], *base = baseline[pid];
        // A counter that went backwards is a recycled pid: a new process from zero.
        double watts = 0;
        if (prev && dtSeconds > 0) {
            double delta = before && now >= before.doubleValue ? now - before.doubleValue : (before ? now : 0);
            watts = delta / 1e9 / dtSeconds;
        }
        // Absent from the baseline means the process started after it: all of its energy counts.
        double wh = 0;
        if (baseline) wh = (base && now >= base.doubleValue ? now - base.doubleValue : now) / 3.6e12;
        if (watts < 0.005 && wh < 0.0005) continue;
        NSString *name = groupFor ? groupFor(pid.intValue) : nil;
        if (!name.length) name = @"Other";
        NSMutableDictionary *g = groups[name];
        if (!g) groups[name] = g = [@{@"name": name, @"watts": @0.0, @"wh": @0.0, @"pids": [NSMutableArray array]} mutableCopy];
        [g[@"pids"] addObject:pid];
        g[@"watts"] = @([g[@"watts"] doubleValue] + watts);
        g[@"wh"] = @([g[@"wh"] doubleValue] + wh);
    }
    NSArray *rows = [groups.allValues filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"watts >= 0.05 OR wh >= 0.01"]];
    return SortedBurnRows(rows);
}

static NSArray<NSDictionary *> *SortedBurnRows(NSArray<NSDictionary *> *rows) {
    return [rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double wa = [a[@"watts"] doubleValue], wb = [b[@"watts"] doubleValue];
        if (fabs(wa - wb) > 1e-9) return wa > wb ? NSOrderedAscending : NSOrderedDescending;
        double ha = [a[@"wh"] doubleValue], hb = [b[@"wh"] doubleValue];
        return ha > hb ? NSOrderedAscending : ha < hb ? NSOrderedDescending : [a[@"name"] compare:b[@"name"]];
    }];
}

NSArray<NSDictionary *> *BurnRowsWithUnreadable(NSArray<NSDictionary *> *rows,
                                                NSDictionary<NSNumber *, NSNumber *> *cpuByPid,
                                                NSSet<NSNumber *> *readable,
                                                NSString *(^groupFor)(pid_t pid)) {
    double readWatts = 0, readCPU = 0;
    for (NSDictionary *r in rows) {
        readWatts += [r[@"watts"] doubleValue];
        for (NSNumber *pid in r[@"pids"]) readCPU += cpuByPid[pid].doubleValue;
    }
    double perCore = readCPU >= 10 ? MIN(6.0, MAX(0.3, readWatts / (readCPU / 100.0))) : 1.5;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    for (NSDictionary *r in rows) groups[r[@"name"]] = [r mutableCopy];
    for (NSNumber *pid in cpuByPid) {
        double cpu = cpuByPid[pid].doubleValue;
        if ([readable containsObject:pid] || !(cpu >= 2)) continue;
        NSString *name = groupFor ? groupFor(pid.intValue) : nil;
        if (!name.length) name = @"Other";
        NSMutableDictionary *g = groups[name];
        if (!g) groups[name] = g = [@{@"name": name, @"watts": @0.0, @"wh": @0.0, @"pids": @[]} mutableCopy];
        g[@"pids"] = [g[@"pids"] arrayByAddingObject:pid];
        g[@"watts"] = @([g[@"watts"] doubleValue] + cpu / 100.0 * perCore);
        g[@"estimated"] = @YES;
    }
    return SortedBurnRows(groups.allValues);
}

NSString *SupportVendorFromPath(NSString *path) {
    NSString *prefix = @"/Library/Application Support/";
    NSRange r = [path rangeOfString:prefix];
    if (r.location == NSNotFound) return nil;
    NSArray<NSString *> *parts = [[path substringFromIndex:NSMaxRange(r)] pathComponents];
    if (parts.count < 2) return nil;
    NSString *vendor = parts.firstObject;
    for (NSString *suffix in @[@" for Mac", @"forMac", @"ForMac"])
        if ([vendor hasSuffix:suffix] && vendor.length > suffix.length) vendor = [vendor substringToIndex:vendor.length - suffix.length];
    return vendor.length ? vendor : nil;
}

#pragma mark - Battery arrival forecasts

static long BatteryCapacityValue(id value, BOOL allowZero) {
    if (![value isKindOfClass:NSNumber.class]) return LONG_MIN;
    double n = [value doubleValue];
    return isfinite(n) && n >= (allowZero ? 0 : 101) && n < 100000 ? (long)n : LONG_MIN;
}
void BatteryApplyCapacities(BatteryState *b, NSDictionary *properties) {
    NSDictionary *data = [properties[@"BatteryData"] isKindOfClass:NSDictionary.class] ? properties[@"BatteryData"] : nil;
    b->rawMax_mAh = BatteryCapacityValue(properties[@"AppleRawMaxCapacity"], NO);
    b->rawCurrent_mAh = BatteryCapacityValue(properties[@"AppleRawCurrentCapacity"], YES);
    // Keep remaining/full from one source; do not mix independently calibrated pairs.
    if (b->rawMax_mAh == LONG_MIN || b->rawCurrent_mAh == LONG_MIN) {
        b->rawMax_mAh = BatteryCapacityValue(data[@"FullChargeCapacity"], NO);
        b->rawCurrent_mAh = BatteryCapacityValue(data[@"RemainingCapacity"], YES);
    }
    if (b->rawMax_mAh > 0 && b->rawCurrent_mAh > b->rawMax_mAh * 1.05)
        b->rawCurrent_mAh = LONG_MIN;
    b->designCap_mAh = BatteryCapacityValue(properties[@"DesignCapacity"], NO);
    if (b->designCap_mAh == LONG_MIN) b->designCap_mAh = BatteryCapacityValue(data[@"DesignCapacity"], NO);
}

static BOOL BatteryMinutesValid(long value) { return value > 0 && value <= 24 * 60; }
void BatteryApplySystemTimes(BatteryState *b, NSDictionary *source) {
    // These strings are the public IOPSKeys.h keys (Foundation-only for tests).
    BOOL charging = [source[@"Is Charging"] boolValue];
    BOOL onBattery = [source[@"Power Source State"] isEqual:@"Battery Power"];
    id empty = source[@"Time to Empty"], full = source[@"Time to Full Charge"];
    b->minutesToEmpty = !b->acConnected && !b->isCharging && onBattery && !charging &&
        [empty isKindOfClass:NSNumber.class] && BatteryMinutesValid([empty longValue]) ? [empty longValue] : -1;
    b->minutesToFull = b->acConnected && b->isCharging && charging && !onBattery &&
        [full isKindOfClass:NSNumber.class] && BatteryMinutesValid([full longValue]) ? [full longValue] : -1;
}

@implementation BatteryForecastTracker {
    NSMutableArray<NSDictionary *> *_samples;
    double _lastUpdate, _lastSample, _thresholdTime, _endpointTime;
    NSInteger _mode;
    BOOL _limit80, _thresholdFromSystem;
}
- (BatteryForecast)update:(BatteryState)b limit80:(BOOL)limit80 at:(double)now {
    // Times go on whichever side is winning: a charger that falls short of the load
    // forecasts 20% and empty, like running on battery.
    BOOL filling = b.acConnected && !ChargerFallsShort(b);
    BatteryForecast f = {.thresholdPercent=filling ? 80 : 20, .endpointPercent=filling ? 100 : 0};
    f.thresholdReached = b.valid && (filling ? b.percent >= 80 : b.percent <= 20);
    f.endpointReached = b.valid && (filling ? b.fullyCharged || b.percent >= 100 : b.percent <= 0);
    f.hideLabels = b.valid && filling && limit80 && b.percent >= 80;
    f.hypotheticalFull = filling && limit80 && !f.hideLabels;
    double watts = BatteryWatts(b);
    BOOL fresh = b.telemetryTimestamp <= 0 || (now - b.telemetryTimestamp >= -5 && now - b.telemetryTimestamp <= 120);
    NSInteger mode = !b.valid || !fresh || f.endpointReached || f.hideLabels ? 0 :
        // macOS keeps IsCharging set behind a short charger while the pack loses charge;
        // there the measured net watts decide.
        filling ? (b.isCharging && watts >= 0.5 ? 1 : 0) :
        ((!b.isCharging || b.acConnected) && watts < -0.5 ? -1 : 0);
    double dt = now - _lastUpdate;
    if (!_samples || mode != _mode || limit80 != _limit80 || dt < 0 || dt > 90 || mode == 0) {
        _samples = [NSMutableArray array]; _lastSample = 0;
        _thresholdTime = 0; _endpointTime = 0;
    }
    _mode = mode; _limit80 = limit80; _lastUpdate = now;
    BatteryForecastReason stopped = !b.valid ? BatteryForecastUnknown : !fresh ? BatteryForecastStale :
        f.hideLabels ? BatteryForecastLimited : BatteryForecastPaused;
    f.thresholdReason = f.thresholdReached ? BatteryForecastReached : stopped;
    f.endpointReason = f.endpointReached ? BatteryForecastReached : stopped;
    if (mode == 0) return f;

    // A new load regime must earn its own rate estimate. Repeated UI renders do not
    // count as independent samples. Units are charge (mAh/mA), avoiding voltage noise.
    double current = fabs((double)b.amperage_mA);
    if (!_lastSample || now - _lastSample >= 10) {
        double prior = [_samples.lastObject[@"amps"] doubleValue];
        if (prior > 0 && fabs(current - prior) / prior > 0.30) [_samples removeAllObjects];
        [_samples addObject:@{@"at":@(now), @"amps":@(current)}]; _lastSample = now;
        while (_samples.count && now - [_samples.firstObject[@"at"] doubleValue] > 90) [_samples removeObjectAtIndex:0];
    }
    double mean = 0, variance = 0;
    for (NSDictionary *s in _samples) mean += [s[@"amps"] doubleValue];
    mean /= MAX((NSUInteger)1, _samples.count);
    for (NSDictionary *s in _samples) variance += pow([s[@"amps"] doubleValue] - mean, 2);
    BOOL steady = _samples.count >= 4 && now - [_samples.firstObject[@"at"] doubleValue] >= 60 &&
        mean > 1 && sqrt(variance / _samples.count) / mean <= 0.20;
    double threshold = -1, endpoint = -1;
    f.thresholdReason = f.thresholdReached ? BatteryForecastReached :
        b.rawMax_mAh <= 0 ? BatteryForecastCapacityMissing : BatteryForecastMeasuring;
    f.endpointReason = mode > 0 ? BatteryForecastSystemMissing :
        b.rawMax_mAh <= 0 || b.rawCurrent_mAh <= 0 ? BatteryForecastCapacityMissing : BatteryForecastMeasuring;
    if (mode < 0) {
        if (BatteryMinutesValid(b.minutesToEmpty)) endpoint = b.minutesToEmpty;
        else if (steady && b.rawCurrent_mAh > 0 && b.rawMax_mAh > 0 && b.rawCurrent_mAh <= b.rawMax_mAh * 1.05)
            endpoint = b.rawCurrent_mAh / mean * 60;
        if (!f.thresholdReached && endpoint > 0) threshold = endpoint * (b.percent - 20.0) / b.percent;
    } else {
        // While below the enabled limit, full is a hypothetical arrival if that
        // limit is cancelled. Only macOS's taper-aware full estimate can supply it.
        if (BatteryMinutesValid(b.minutesToFull)) endpoint = b.minutesToFull;
        if (!f.thresholdReached && steady && b.rawMax_mAh > 0)
            threshold = (80.0 - b.percent) / 100.0 * b.rawMax_mAh / mean * 60;
        // A linear pre-80 estimate must not contradict the system's tapered full estimate.
        if (endpoint > 0 && threshold > endpoint) { threshold = -1; f.thresholdReason = BatteryForecastInconsistent; }
        if (!f.thresholdReached && threshold <= 0 && endpoint > 0) {
            // powerd already has history at launch. Use the remaining charge share
            // of its full-time estimate provisionally, rather than hiding 80% for
            // a minute. The full-time tail includes taper, so this can run long;
            // replace it with the measured pre80 rate once that rate is steady.
            // This NEVER invents a full-time estimate from a single current sample.
            threshold = endpoint * (80.0 - b.percent) / (100.0 - b.percent);
            f.thresholdFromSystem = YES;
        }
    }
    // A measured pre80 rate supersedes the conservative startup source. Do not
    // keep blending the old source into a newly supported near-target estimate.
    if (f.thresholdFromSystem != _thresholdFromSystem) _thresholdTime = 0;
    _thresholdFromSystem = f.thresholdFromSystem;
    double (^smooth)(double, double) = ^double(double minutes, double previous) {
        if (!isfinite(minutes) || minutes <= 0 || minutes > 1440) return 0;
        double candidate = now + minutes * 60;
        if (previous <= now || dt <= 0 || fabs(candidate - previous) > MAX(300, minutes * 60 * 0.25)) return candidate;
        return previous + (candidate - previous) * (1 - exp(-dt / 30.0));
    };
    f.thresholdTime = _thresholdTime = smooth(threshold, _thresholdTime);
    f.endpointTime = _endpointTime = smooth(endpoint, _endpointTime);
    if (f.thresholdTime > 0) f.thresholdReason = BatteryForecastReady;
    if (f.endpointTime > 0) f.endpointReason = BatteryForecastReady;
    return f;
}
@end

NSString *BatteryForecastDuration(double arrival, double now) {
    double minutes = (arrival - now) / 60.0;
    if (!isfinite(arrival) || !isfinite(now) || arrival <= 0 || !isfinite(minutes) || minutes <= 0 || minutes > 1440)
        return @"—";
    if (minutes < 5) return @"<5m";
    int roundedMinutes = (int)lround(minutes / 5.0) * 5;
    // Promote a rounded 60m to 1h, so the minute/hour boundary never shows 60m.
    if (roundedMinutes < 60) return [NSString stringWithFormat:@"%dm", roundedMinutes];
    int tenths = (int)lround(minutes / 6.0);
    if (tenths >= 100) return [NSString stringWithFormat:@"%dh", (int)lround(minutes / 60.0)];
    if (tenths % 10 == 0) return [NSString stringWithFormat:@"%dh", tenths / 10];
    return [NSString stringWithFormat:@"%d.%dh", tenths / 10, tenths % 10];
}

static double BatteryRoundedArrival(double arrival) { return round(arrival / 300.0) * 300.0; }
NSString *BatteryForecastClock(double arrival, NSTimeZone *zone) {
    if (!isfinite(arrival) || arrival <= 0) return @"—";
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = zone ?: NSTimeZone.localTimeZone; formatter.dateFormat = @"HHmm";
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:BatteryRoundedArrival(arrival)]];
}
NSString *BatteryForecastDetail(BatteryForecast f, double now, NSTimeZone *zone) {
    if (f.hideLabels) return @"80% charge limit reached";
    NSMutableArray *parts = [NSMutableArray array];
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = zone ?: NSTimeZone.localTimeZone;
    NSDate *today = [calendar startOfDayForDate:[NSDate dateWithTimeIntervalSince1970:now]];
    double times[] = {f.thresholdTime, f.endpointTime};
    int targets[] = {f.thresholdPercent, f.endpointPercent};
    BOOL reached[] = {f.thresholdReached, f.endpointReached};
    for (int i=0; i<2; i++) {
        if (reached[i]) continue;
        if (!isfinite(times[i]) || times[i] <= now) { [parts addObject:[NSString stringWithFormat:@"%d%% —", targets[i]]]; continue; }
        NSDate *day = [calendar startOfDayForDate:[NSDate dateWithTimeIntervalSince1970:BatteryRoundedArrival(times[i])]];
        NSInteger days = [calendar components:NSCalendarUnitDay fromDate:today toDate:day options:0].day;
        NSString *suffix = days > 0 ? [NSString stringWithFormat:@" +%ldd", (long)days] : @"";
        [parts addObject:[NSString stringWithFormat:@"%d%% ~%@%@", targets[i], BatteryForecastClock(times[i], zone), suffix]];
    }
    return [parts componentsJoinedByString:@" · "];
}

NSString *BatteryForecastStatus(BatteryForecast f) {
    if (f.hideLabels) return @"Forecasts hidden at the enabled 80% limit";
    NSMutableArray *parts = [NSMutableArray array];
    BatteryForecastReason reasons[] = {f.thresholdReason, f.endpointReason};
    int targets[] = {f.thresholdPercent, f.endpointPercent};
    for (int i=0; i<2; i++) {
        NSString *reason = nil;
        switch (reasons[i]) {
            case BatteryForecastReady: case BatteryForecastReached: break;
            case BatteryForecastMeasuring: reason = @"measuring a steady rate"; break;
            case BatteryForecastCapacityMissing: reason = @"battery capacity unavailable"; break;
            case BatteryForecastStale: reason = @"waiting for fresh battery data"; break;
            case BatteryForecastPaused: reason = @"charging paused"; break;
            case BatteryForecastLimited: reason = @"80% charge limit reached"; break;
            case BatteryForecastSystemMissing: reason = @"macOS full-charge estimate unavailable"; break;
            case BatteryForecastInconsistent: reason = @"charge estimates settling"; break;
            default: reason = @"battery estimate unavailable"; break;
        }
        if (reason) [parts addObject:[NSString stringWithFormat:@"%d%%: %@", targets[i], reason]];
    }
    if (f.hypotheticalFull) [parts addObject:@"100% assumes the 80% limit is cancelled"];
    if (f.thresholdFromSystem) [parts addObject:@"80%: provisional from macOS full time; may run long"];
    if (f.thresholdTime > 0 || f.endpointTime > 0) [parts addObject:@"Approximate arrivals · local time"];
    return [parts componentsJoinedByString:@"\n"];
}

ThermalLevel ThermalLevelFor(int pressure) {
    if (pressure < 0) return ThermalUnknown;
    if (pressure >= 2) return ThermalThrottling;
    return pressure == 1 ? ThermalNear : ThermalNominal;
}

NSString *ThermalPressureName(int pressure) {
    NSArray *names = @[@"nominal", @"moderate", @"heavy", @"trapping", @"sleeping"];
    if (pressure < 0) return nil;
    return pressure < (int)names.count ? names[pressure] : [NSString stringWithFormat:@"level %d", pressure];
}

NSString *ThermalDatumText(double tempC, ThermalLevel level) {
    if (level != ThermalNear && level != ThermalThrottling) return nil;   // quiet while cool
    if (tempC <= 0) return level == ThermalThrottling ? @"slowed" : level == ThermalNear ? @"near limit" : nil;
    long t = lround(tempC);
    return level == ThermalThrottling ? [NSString stringWithFormat:@"%ld° slowed", t]
                                      : [NSString stringWithFormat:@"%ld °C", t];
}

static const double kBatteryWarmC = 38, kBatteryHotC = 42, kBatteryCoolC = 35;

BatteryHeat BatteryHeatFor(double tempC) {
    tempC = round(tempC);   // judge the whole degree the row shows, so "42 °C" is never orange
    if (tempC >= kBatteryHotC) return BatteryHeatHot;
    return tempC >= kBatteryWarmC ? BatteryHeatWarm : BatteryHeatNone;
}

NSString *BatteryHeatText(double tempC) {
    return BatteryHeatFor(tempC) == BatteryHeatNone ? nil : [NSString stringWithFormat:@"%ld °C", lround(tempC)];
}

BOOL HeatShowing(BOOL always, ThermalLevel chip, double cellC) {
    if (always) return YES;
    return chip == ThermalNear || chip == ThermalThrottling || BatteryHeatFor(cellC) != BatteryHeatNone;
}

NSArray<NSNumber *> *DVFSTableMHz(NSData *blob) {
    NSMutableArray *out = [NSMutableArray array];
    const uint8_t *bytes = blob.bytes;
    double top = 0;
    for (NSUInteger i = 0; i + 8 <= blob.length; i += 8) {
        uint32_t raw = (uint32_t)bytes[i] | (uint32_t)bytes[i + 1] << 8 | (uint32_t)bytes[i + 2] << 16 | (uint32_t)bytes[i + 3] << 24;
        if (raw) { [out addObject:@(raw)]; top = MAX(top, raw); }
    }
    // M5 stores kHz (4464000), M2 stores Hz (3504000000). No core clocks past 100 GHz.
    double perMHz = top > 1e8 ? 1e6 : 1e3;
    for (NSUInteger i = 0; i < out.count; i++) out[i] = @([out[i] doubleValue] / perMHz);
    return out;
}

double ClusterActiveMHz(NSArray<NSString *> *states, NSArray<NSNumber *> *residency,
                        NSArray<NSNumber *> *tableMHz, double *busy) {
    double total = 0, active = 0, weighted = 0;
    for (NSUInteger i = 0; i < states.count && i < residency.count; i++) {
        double r = MAX(0, residency[i].doubleValue);
        total += r;
        NSString *name = states[i];
        if (![name hasPrefix:@"V"]) continue;   // IDLE, OFF, DOWN
        NSInteger k = [[name substringFromIndex:1] integerValue];
        if (k < 0 || k >= (NSInteger)tableMHz.count) continue;
        active += r;
        weighted += r * tableMHz[k].doubleValue;
    }
    if (busy) *busy = total > 0 ? active / total : 0;
    return active > 0 ? weighted / active : 0;
}

double HeatSpeedFraction(ThermalLevel level, double activeMHz, double maxMHz, double busy, double last) {
    if (level == ThermalUnknown) return -1;
    if (level == ThermalNominal) return 1;
    if (busy >= 0.5 && activeMHz > 0 && maxMHz > 0) return MIN(1, activeMHz / maxMHz);
    return last;
}

HeatGuardAction HeatGuardStep(BOOL enabled, double tempC, BOOL lowPowerOn, HeatGuardState *state) {
    BOOL cool = tempC > 0 && tempC <= kBatteryCoolC;
    switch (*state) {
        case HeatGuardEngaged:
            if (!lowPowerOn) { *state = HeatGuardStoodDown; return HeatGuardNothing; }   // the user switched it off
            if (!enabled || cool) { *state = HeatGuardIdle; return HeatGuardDisable; }
            return HeatGuardNothing;
        case HeatGuardStoodDown:
            if (!enabled || cool) *state = HeatGuardIdle;
            return HeatGuardNothing;
        case HeatGuardIdle:
        default:
            if (enabled && !lowPowerOn && tempC >= kBatteryWarmC) { *state = HeatGuardEngaged; return HeatGuardEnable; }
            return HeatGuardNothing;
    }
}

NSString *OutputVolumeText(double volume, BOOL muted) {
    if (muted) return @"mute";
    if (volume < 0) return @"—";
    return [NSString stringWithFormat:@"%ld%%", lround(MIN(1, volume) * 100)];
}

BOOL OutputVolumeLoud(double volume) { return lround(volume * 100) >= 80; }

#pragma mark - Seed mixes

NSString *GenreFamily(NSString *genre) {
    NSString *g = genre.lowercaseString ?: @"";
    for (NSString *k in @[@"electronic", @"dance", @"house", @"techno", @"trance", @"bass", @"drum", @"dubstep", @"garage", @"electronica", @"downtempo", @"ambient"])
        if ([g containsString:k]) return @"dance";
    for (NSString *k in @[@"hip-hop", @"hip hop", @"rap", @"r&b", @"soul", @"funk", @"grime", @"trap"])
        if ([g containsString:k]) return @"rap";
    for (NSString *k in @[@"alternative", @"rock", @"indie", @"punk", @"metal", @"grunge", @"emo", @"folk", @"singer"])
        if ([g containsString:k]) return @"alt";
    if ([g containsString:@"pop"]) return @"pop";
    return @"other";
}

// A small deterministic generator so seeds and fallback mixes are testable.
static uint64_t MixNext(uint64_t *state) {
    *state = *state * 6364136223846793005ULL + 1442695040888963407ULL;
    return *state >> 33;
}

static double MixTrackWeight(NSDictionary *t) {
    double w = 1 + log1p([t[@"plays"] doubleValue]);
    if ([t[@"fav"] boolValue]) w *= 2;
    return w;
}

// Seeds are songs Ian will recognise: ones he has actually played here, weighted by plays and how
// recently. Favourites alone mean little (1,240 of 1,412 were bulk-imported YouTube likes, 30 Oct 2026),
// so they only fill in when too few played songs are left.
NSArray<NSDictionary *> *ChooseMixSeeds(NSArray<NSDictionary *> *tracks, NSArray<NSString *> *recentKeys,
                                        NSUInteger count, uint64_t salt) {
    NSSet *recent = [NSSet setWithArray:recentKeys ?: @[]];
    NSMutableArray *played = [NSMutableArray array], *favs = [NSMutableArray array];   // candidate seeds with a weight
    for (NSDictionary *t in tracks) {
        if ([t[@"dislike"] boolValue] || ![t[@"id"] length] || ![t[@"title"] length]) continue;
        NSString *key = [@"song:" stringByAppendingString:t[@"id"]];
        if ([recent containsObject:key]) continue;
        NSInteger plays = [t[@"plays"] integerValue], idle = [t[@"idleDays"] integerValue];
        BOOL thumb = [t[@"thumb"] boolValue];   // 👍 in Glancebar: Ian said he likes it
        double weight = (1 + log1p(plays)) * ([t[@"fav"] boolValue] ? 1.5 : 1) * (thumb ? 3 : 1);
        if (plays > 0 && idle >= 0) weight *= 1 + 2.0 / (1 + idle / 30.0);   // played this month counts most
        NSDictionary *seed = @{@"key": key, @"kind": @"song", @"title": t[@"title"], @"subtitle": t[@"artist"] ?: @"",
                               @"trackID": t[@"id"], @"artist": t[@"artist"] ?: @"", @"album": t[@"album"] ?: @"",
                               @"family": GenreFamily(t[@"genre"]), @"weight": @(weight)};
        if (plays > 0 || thumb) [played addObject:seed];
        else if ([t[@"fav"] boolValue]) [favs addObject:seed];
    }
    NSComparator byKey = ^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"key"] compare:b[@"key"]]; };
    [played sortUsingComparator:byKey]; [favs sortUsingComparator:byKey];
    uint64_t state = salt ^ 0x9E3779B97F4A7C15ULL;
    NSMutableArray *chosen = [NSMutableArray array];
    NSMutableSet *families = [NSMutableSet set], *artists = [NSMutableSet set];
    for (NSMutableArray *pool in @[played, favs]) {
        // Prefer a family not yet shown; never the same artist twice.
        for (NSUInteger round = 0; chosen.count < count && pool.count && round < count * 40; round++) {
            double total = 0;
            NSMutableArray *eligible = [NSMutableArray array];
            for (NSDictionary *s in pool) {
                if ([artists containsObject:[s[@"artist"] lowercaseString]]) continue;
                BOOL fresh = ![families containsObject:s[@"family"]] || families.count >= 4;
                if (round < count * 20 && !fresh) continue;
                [eligible addObject:s]; total += [s[@"weight"] doubleValue];
            }
            if (!eligible.count) continue;
            double r = (MixNext(&state) % 1000000) / 1000000.0 * total;
            NSDictionary *pick = eligible.lastObject;
            for (NSDictionary *s in eligible) { r -= [s[@"weight"] doubleValue]; if (r <= 0) { pick = s; break; } }
            NSMutableDictionary *seed = [pick mutableCopy]; [seed removeObjectForKey:@"weight"];
            [chosen addObject:seed];
            [families addObject:pick[@"family"]];
            [artists addObject:[pick[@"artist"] lowercaseString]];
            [pool removeObject:pick];
        }
    }
    return chosen;
}

// 👍 feedback for the curator, one JSON object per line in mix/feedback.jsonl; the last line for a
// track wins, so un-liking is just another line.
static NSString *SelectorNormaliseField(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length) return @"";
    NSString *text = [[value stringByReplacingOccurrencesOfString:@"\u00A0" withString:@" "] lowercaseString];
    static NSCharacterSet *drop;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *keep = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
        [keep addCharactersInString:@"_"];
        drop = [keep invertedSet];
    });
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [text componentsSeparatedByCharactersInSet:drop])
        if (part.length) [parts addObject:part];
    return [parts componentsJoinedByString:@" "];
}

NSString *SelectorTrackKey(NSString *artist, NSString *title) {
    NSString *a = SelectorNormaliseField(artist), *t = SelectorNormaliseField(title);
    if (!a.length || !t.length) return nil;
    return [NSString stringWithFormat:@"%@|%@", a, t];
}

NSString *SelectorFeedbackLine(NSString *artist, NSString *title, NSString *source, NSDate *at) {
    NSString *key = SelectorTrackKey(artist, title);
    if (!key.length) return nil;
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    (void)source;   // Selector's feedback contract (docs/contracts.md) has no source on a like; it would fail validation.
    NSDictionary *line = @{@"artist": artist ?: @"", @"at": [fmt stringFromDate:at ?: NSDate.date], @"event": @"like",
                           @"title": title ?: @"", @"track_key": key};
    NSData *data = [NSJSONSerialization dataWithJSONObject:line options:NSJSONWritingSortedKeys error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static BOOL SelectorSamePath(NSString *a, NSString *b) {
    if (![a isKindOfClass:NSString.class] || ![b isKindOfClass:NSString.class] || !a.length || !b.length) return NO;
    if ([a isEqual:b]) return YES;
    return [a.stringByStandardizingPath isEqual:b.stringByStandardizingPath];
}

static NSString *SelectorRowFile(NSDictionary *row) {
    NSString *file = [row[@"file"] isKindOfClass:NSString.class] ? row[@"file"] : @"";
    if (!file.length && [row[@"path"] isKindOfClass:NSString.class]) file = row[@"path"];
    return file ?: @"";
}

static NSString *SelectorRowKey(NSDictionary *row) {
    NSString *key = [row[@"track_key"] isKindOfClass:NSString.class] ? row[@"track_key"] : @"";
    if (!key.length && [row[@"key"] isKindOfClass:NSString.class]) key = row[@"key"];
    return [key containsString:@"|"] ? key : @"";
}

NSDictionary *LocalTrackIdentity(NSArray *stationRows, NSString *path, NSString *tagArtist, NSString *tagTitle, NSString *filename) {
    NSString *artist = nil, *title = nil, *key = nil;
    for (id item in stationRows) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row = item;
        if (!SelectorSamePath(SelectorRowFile(row), path)) continue;
        NSString *rowArtist = [row[@"artist"] isKindOfClass:NSString.class] ? row[@"artist"] : @"";
        NSString *rowTitle = [row[@"title"] isKindOfClass:NSString.class] ? row[@"title"] : @"";
        if (!rowArtist.length || !rowTitle.length) continue;
        artist = rowArtist;
        title = rowTitle;
        key = SelectorRowKey(row);
        break;
    }
    if (!artist.length && [tagArtist isKindOfClass:NSString.class] && tagArtist.length &&
        [tagTitle isKindOfClass:NSString.class] && tagTitle.length) {
        artist = tagArtist;
        title = tagTitle;
    }
    NSDictionary *parsed = ParseLikedTrackFilename(filename);
    if (![parsed[@"trackID"] length]) parsed = ParseLikedTrackFilename(path);
    if (!artist.length) {
        NSString *fileArtist = parsed[@"artist"] ?: @"";
        NSString *fileTitle = parsed[@"title"] ?: @"";
        if (fileArtist.length && fileTitle.length) { artist = fileArtist; title = fileTitle; }
    }
    if (!artist.length || !title.length) return nil;
    if (!key.length) key = SelectorTrackKey(artist, title);
    if (!key.length) return nil;
    return @{@"artist": artist, @"title": title, @"trackKey": key, @"trackID": parsed[@"trackID"] ?: @""};
}

NSArray<NSString *> *HeartCacheKeys(NSString *json) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id obj = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *tracks = [obj isKindOfClass:NSDictionary.class] ? obj[@"tracks"] : nil;
    if (![tracks isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id item in tracks) if ([item isKindOfClass:NSString.class] && [item length]) [out addObject:item];
    return out;
}

NSString *HeartCacheAdding(NSString *json, NSString *key) {
    NSMutableArray *tracks = [HeartCacheKeys(json) mutableCopy];
    if (key.length && ![tracks containsObject:key]) [tracks addObject:key];
    [tracks sortUsingSelector:@selector(compare:)];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"tracks": tracks} options:NSJSONWritingSortedKeys error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

BOOL HeartCacheContains(NSString *json, NSString *key) {
    return key.length && [HeartCacheKeys(json) containsObject:key];
}

NSString *MixFeedbackLine(NSString *trackID, NSString *title, NSString *artist, BOOL liked, NSDate *at) {
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
    NSDictionary *o = @{@"at": [f stringFromDate:at ?: NSDate.date], @"trackID": trackID ?: @"", @"title": title ?: @"",
                        @"artist": artist ?: @"", @"liked": @(liked)};
    NSData *d = [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:nil];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
}

NSSet<NSString *> *MixLikedIDs(NSString *jsonl) {
    NSMutableSet *liked = [NSMutableSet set];
    for (NSString *line in [jsonl ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *o = line.length ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if (![o isKindOfClass:NSDictionary.class] || ![o[@"trackID"] isKindOfClass:NSString.class] || ![o[@"trackID"] length]) continue;
        if ([o[@"liked"] boolValue]) [liked addObject:o[@"trackID"]]; else [liked removeObject:o[@"trackID"]];
    }
    return liked;
}

// A seed's cover when Music has none on this Mac (streamed tracks report artwork "downloaded: false"):
// Apple's public iTunes search, no account.
NSURL *MixArtSearchURL(NSString *artist, NSString *title) {
    NSURLComponents *c = [NSURLComponents componentsWithString:@"https://itunes.apple.com/search"];
    c.queryItems = @[[NSURLQueryItem queryItemWithName:@"term" value:[NSString stringWithFormat:@"%@ %@", artist ?: @"", SeedCaption(title)]],
                     [NSURLQueryItem queryItemWithName:@"entity" value:@"song"],
                     [NSURLQueryItem queryItemWithName:@"limit" value:@"5"],
                     [NSURLQueryItem queryItemWithName:@"country" value:@"au"]];
    return c.URL;
}

// The cover URL at `px` square from a search reply: the same artist exactly beats a looser match, and
// instrumental/karaoke/tribute releases never win (Kiss Me More got an instrumental's cover, 1 Nov 2026).
NSString *MixArtURLFromSearch(NSData *json, NSString *artist, NSUInteger px) {
    NSDictionary *reply = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    NSArray *results = [reply isKindOfClass:NSDictionary.class] ? reply[@"results"] : nil;
    if (![results isKindOfClass:NSArray.class]) return nil;
    NSString *want = artist.lowercaseString ?: @"", *best = nil;
    NSInteger bestScore = -1;
    for (NSDictionary *r in results) {
        if (![r isKindOfClass:NSDictionary.class] || ![r[@"artworkUrl100"] isKindOfClass:NSString.class]) continue;
        NSString *by = [r[@"artistName"] isKindOfClass:NSString.class] ? [r[@"artistName"] lowercaseString] : @"";
        NSString *names = [NSString stringWithFormat:@"%@ %@ %@", by, [r[@"trackName"] isKindOfClass:NSString.class] ? r[@"trackName"] : @"",
                           [r[@"collectionName"] isKindOfClass:NSString.class] ? r[@"collectionName"] : @""].lowercaseString;
        BOOL cover = NO;
        for (NSString *k in @[@"instrumental", @"karaoke", @"tribute", @"made famous", @"in the style of", @"backing track"])
            cover |= [names containsString:k];
        NSInteger score = cover ? 0 : [by isEqualToString:want] ? 3 : (want.length && ([by containsString:want] || [want containsString:by])) ? 2 : 1;
        if (score > bestScore) { bestScore = score; best = r[@"artworkUrl100"]; }
    }
    return [best stringByReplacingOccurrencesOfString:@"100x100bb" withString:[NSString stringWithFormat:@"%lux%lubb", (unsigned long)px, (unsigned long)px]];
}

static BOOL MixTrackInSeed(NSDictionary *t, NSDictionary *seed) {
    if ([seed[@"kind"] isEqual:@"album"])
        return [[t[@"album"] lowercaseString] isEqual:[seed[@"album"] lowercaseString]] &&
               [[t[@"artist"] lowercaseString] isEqual:[seed[@"artist"] lowercaseString]];
    return [t[@"id"] isEqual:seed[@"trackID"]];
}

NSArray<NSDictionary *> *MixCandidates(NSArray<NSDictionary *> *tracks, NSDictionary *seed,
                                       NSInteger minIdleDays, NSUInteger limit) {
    NSString *family = seed[@"family"], *artist = [seed[@"artist"] lowercaseString];
    NSInteger seedYear = 0;
    for (NSDictionary *t in tracks) if ([t[@"id"] isEqual:seed[@"trackID"]]) { seedYear = [t[@"year"] integerValue]; break; }
    NSMutableArray *scored = [NSMutableArray array];
    for (NSDictionary *t in tracks) {
        if ([t[@"dislike"] boolValue] || MixTrackInSeed(t, seed)) continue;
        NSInteger idle = [t[@"idleDays"] integerValue];
        if (idle >= 0 && idle < minIdleDays) continue;
        double score = 0;
        if ([[t[@"artist"] lowercaseString] isEqual:artist]) score += 3;
        NSString *f = GenreFamily(t[@"genre"]);
        if ([f isEqual:family]) score += 2;
        else if ([f isEqual:@"other"] || [family isEqual:@"other"]) score += 0.5;
        NSInteger year = [t[@"year"] integerValue];
        if (seedYear > 0 && year > 0) score += MAX(0, 1.5 - labs(year - seedYear) / 6.0);
        score += log1p(MixTrackWeight(t)) * 0.5;
        if (score < 2) continue;   // a different family with nothing else in common doesn't belong
        NSMutableDictionary *c = [t mutableCopy]; c[@"score"] = @(score);
        [scored addObject:c];
    }
    [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult r = [b[@"score"] compare:a[@"score"]];
        return r != NSOrderedSame ? r : [a[@"id"] compare:b[@"id"]];
    }];
    return scored.count > limit ? [scored subarrayWithRange:NSMakeRange(0, limit)] : scored;
}

NSArray<NSDictionary *> *MixSeedTracks(NSDictionary *seed, NSArray<NSDictionary *> *tracks) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *t in tracks) if (MixTrackInSeed(t, seed) && ![t[@"dislike"] boolValue]) [out addObject:t];
    if ([seed[@"kind"] isEqual:@"album"]) {
        // The album's standouts open the mix: favourites and most played, up to four.
        [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSComparisonResult r = [@(MixTrackWeight(b)) compare:@(MixTrackWeight(a))];
            return r != NSOrderedSame ? r : [a[@"id"] compare:b[@"id"]];
        }];
        if (out.count > 4) [out removeObjectsInRange:NSMakeRange(4, out.count - 4)];
    }
    return out;
}

NSArray<NSString *> *RuleMix(NSArray<NSDictionary *> *candidates, NSDictionary *seed,
                             NSArray<NSDictionary *> *tracks, NSUInteger length, uint64_t salt) {
    NSMutableArray *ids = [NSMutableArray array];
    NSMutableArray *openers = [MixSeedTracks(seed, tracks) mutableCopy];
    NSMutableArray *pool = [candidates mutableCopy];
    uint64_t state = salt ^ 0xD1B54A32D192ED03ULL;
    NSString *lastArtist = nil;
    if (openers.count) { [ids addObject:openers[0][@"id"]]; lastArtist = [openers[0][@"artist"] lowercaseString]; [openers removeObjectAtIndex:0]; }
    while (ids.count < length && (pool.count || openers.count)) {
        // An album seed's other standouts are spread through the first half.
        if (openers.count && ids.count % 3 == 0) {
            NSDictionary *o = openers.firstObject;
            [ids addObject:o[@"id"]]; lastArtist = [o[@"artist"] lowercaseString]; [openers removeObjectAtIndex:0];
            continue;
        }
        double total = 0;
        NSMutableArray *eligible = [NSMutableArray array];
        for (NSDictionary *c in pool) if (![[c[@"artist"] lowercaseString] isEqual:lastArtist]) { [eligible addObject:c]; total += [c[@"score"] doubleValue]; }
        if (!eligible.count) {
            if (!openers.count) break;
            NSDictionary *o = openers.firstObject;   // nothing else fits here: place the next standout now
            [ids addObject:o[@"id"]]; lastArtist = [o[@"artist"] lowercaseString]; [openers removeObjectAtIndex:0];
            continue;
        }
        double r = (MixNext(&state) % 1000000) / 1000000.0 * total;
        NSDictionary *pick = eligible.lastObject;
        for (NSDictionary *c in eligible) { r -= [c[@"score"] doubleValue]; if (r <= 0) { pick = c; break; } }
        [ids addObject:pick[@"id"]]; lastArtist = [pick[@"artist"] lowercaseString];
        [pool removeObject:pick];
    }
    return ids;
}

NSString *MixPrompt(NSDictionary *seed, NSArray<NSDictionary *> *candidates, NSUInteger length) {
    NSMutableString *p = [NSMutableString string];
    BOOL album = [seed[@"kind"] isEqual:@"album"];
    [p appendFormat:@"You are a DJ building a %lu-track listening session from one person's music library.\n", (unsigned long)length];
    [p appendFormat:@"Seed %@: \"%@\" by %@.\n", album ? @"album" : @"song", album ? seed[@"album"] : seed[@"title"], seed[@"artist"]];
    [p appendString:@"Pick tracks ONLY from the candidates below and put them in a good listening order: start close to "
                     "the seed's sound, drift gradually, keep energy coherent, never the same artist twice in a row, "
                     "at most 3 tracks per artist. Use your knowledge of the artists and songs, not just the genre labels.\n"];
    if (album) [p appendString:@"Weave in a few of the seed album's own tracks if they are listed.\n"];
    [p appendFormat:@"Reply with ONLY a JSON array of %lu candidate ids, in order. No other text.\n\nCandidates (id | artist | title | genre | year):\n", (unsigned long)length];
    for (NSDictionary *c in candidates)
        [p appendFormat:@"%@ | %@ | %@ | %@ | %@\n", c[@"id"], c[@"artist"] ?: @"", c[@"title"] ?: @"", c[@"genre"] ?: @"",
            [c[@"year"] integerValue] > 0 ? c[@"year"] : @"?"];
    return p;
}

NSArray<NSString *> *ParseMixReply(NSString *reply, NSSet<NSString *> *allowed, NSUInteger maxLength) {
    NSRange open = [reply rangeOfString:@"["], close = [reply rangeOfString:@"]" options:NSBackwardsSearch];
    if (open.location == NSNotFound || close.location == NSNotFound || close.location < open.location) return @[];
    NSData *data = [[reply substringWithRange:NSMakeRange(open.location, close.location - open.location + 1)] dataUsingEncoding:NSUTF8StringEncoding];
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id item in json) {
        NSString *id_ = [item isKindOfClass:NSString.class] ? item : [item isKindOfClass:NSNumber.class] ? [item stringValue] : nil;
        if (!id_ || ![allowed containsObject:id_] || [seen containsObject:id_]) continue;
        [seen addObject:id_]; [out addObject:id_];
        if (out.count >= maxLength) break;
    }
    return out;
}

NSArray<NSString *> *LocalSeedFiles(NSDictionary *seed, NSArray<NSString *> *paths) {
    if (![seed isKindOfClass:NSDictionary.class] || ![paths isKindOfClass:NSArray.class]) return @[];
    NSString *rawArtist = [seed[@"artist"] isKindOfClass:NSString.class] ? seed[@"artist"] : @"";
    NSString *artist = [[rawArtist stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    NSString *rawTitle = [seed[@"title"] isKindOfClass:NSString.class] ? seed[@"title"] : @"";
    NSString *title = [[SeedCaption(rawTitle) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    // A one-letter artist or a tiny title would match half the folder.
    if (artist.length < 2 || title.length < 3) return @[];
    NSMutableArray *exact = [NSMutableArray array], *same = [NSMutableArray array];
    for (id item in paths) {
        if (![item isKindOfClass:NSString.class]) continue;
        NSString *base = [(NSString *)item lastPathComponent].lowercaseString;
        if (!base.length || [base hasPrefix:@"."] || ![base hasSuffix:@".m4a"]) continue;
        BOOL hasArtist = [base containsString:artist];
        BOOL hasTitle = [base containsString:title];
        if (hasArtist && hasTitle) [exact addObject:item];
        else if (hasArtist) [same addObject:item];
    }
    NSComparator byPath = ^NSComparisonResult(NSString *a, NSString *b) { return [a compare:b]; };
    [exact sortUsingComparator:byPath];
    [same sortUsingComparator:byPath];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *path in exact) if (out.count < 40) [out addObject:path];
    for (NSString *path in same) if (out.count < 40) [out addObject:path];
    return out;
}

NSDictionary *StationFromJSON(NSData *json) {
    if (![json isKindOfClass:NSData.class] || !json.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (![obj isKindOfClass:NSDictionary.class]) return nil;
    NSArray *queue = [obj[@"queue"] isKindOfClass:NSArray.class] ? obj[@"queue"] : @[];
    NSArray *picksIn = [obj[@"picks"] isKindOfClass:NSArray.class] ? obj[@"picks"] : @[];
    NSMutableArray *files = [NSMutableArray array];
    NSMutableArray *tracks = [NSMutableArray array];
    for (id item in queue) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row = item;
        NSString *file = SelectorRowFile(row);
        if (!file.length) continue;
        [files addObject:file];
        [tracks addObject:@{@"file": file,
                            @"artist": [row[@"artist"] isKindOfClass:NSString.class] ? row[@"artist"] : @"",
                            @"title": [row[@"title"] isKindOfClass:NSString.class] ? row[@"title"] : @"",
                            @"key": SelectorRowKey(row)}];
    }
    NSMutableArray *picks = [NSMutableArray array];
    for (id item in picksIn) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row = item;
        NSString *title = [row[@"title"] isKindOfClass:NSString.class] ? row[@"title"] : @"";
        if (!title.length) continue;
        NSString *artist = [row[@"artist"] isKindOfClass:NSString.class] ? row[@"artist"] : @"";
        NSString *reason = [row[@"reason"] isKindOfClass:NSString.class] ? row[@"reason"] : @"";
        NSString *file = SelectorRowFile(row);
        [picks addObject:@{@"title": title, @"artist": artist, @"reason": reason, @"file": file ?: @""}];
    }
    return @{@"files": files, @"picks": picks, @"tracks": tracks};
}

static void DeckCopyField(char *dst, size_t cap, id value) {
    if (!dst || cap == 0) return;
    dst[0] = '\0';
    if (![value isKindOfClass:NSString.class]) return;
    const char *utf = [(NSString *)value UTF8String];
    if (!utf) return;
    size_t n = strlen(utf);
    if (n >= cap) n = cap - 1;
    if (n) memcpy(dst, utf, n);
    dst[n] = '\0';
}

static double DeckJSONNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NAN;
    double number = [(NSNumber *)value doubleValue];
    return isfinite(number) ? number : NAN;
}

static GBDeckNow DeckNowEmpty(void) {
    GBDeckNow out;
    memset(&out, 0, sizeof(out));
    out.position = NAN;
    out.duration = NAN;
    out.bpm = NAN;
    out.pending.startsInS = NAN;
    out.pending.bars = NAN;
    out.blend.progress = NAN;
    out.blend.elapsedS = NAN;
    out.blend.lengthS = NAN;
    out.blend.bpm = NAN;
    return out;
}

GBDeckNow DeckNowBlank(void) {
    return DeckNowEmpty();
}

static BOOL DeckBlendOpen(GBDeckBlend blend) {
    if (!blend.present) return NO;
    if (!isfinite(blend.progress)) return YES;
    return blend.progress < 1.0;
}

static double DeckMixTimeout(double timeoutSec) {
    if (!isfinite(timeoutSec) || timeoutSec < 0) return kDeckSkipReplyTimeoutSec;
    return timeoutSec;
}

static DeckMixVisual DeckMixClear(double flashUntil, BOOL failed) {
    DeckMixVisual visual = {0};
    visual.flashUntil = flashUntil;
    visual.failed = failed;
    return visual;
}

static BOOL DeckMixTimedOut(DeckMixVisual visual, double now, double timeoutSec) {
    if (visual.phase != DeckMixArmed || visual.replySeen || !(visual.since > 0)) return NO;
    return now - visual.since >= DeckMixTimeout(timeoutSec);
}

// A running blend wins over a pending skip. Neither one, on a reply, ends the
// arm; on a snapshot it ends a mix that was already pending or blending.
static DeckMixVisual DeckMixApplySnapshot(DeckMixVisual visual, DeckMixEvent event,
                                          double now, GBDeckNow snapshot, double timeoutSec) {
    if (DeckBlendOpen(snapshot.blend)) {
        visual.phase = DeckMixBlending;
        visual.failed = NO;
        visual.replySeen = YES;
        return visual;
    }
    if (snapshot.pending.present) {
        visual.phase = DeckMixPending;
        visual.failed = NO;
        visual.replySeen = YES;
        return visual;
    }
    if (event == DeckMixEventReply) {
        // The socket answered and there is nothing to wait for. Older decks and
        // an immediate skip with no blend object both end here.
        return DeckMixClear(visual.flashUntil, NO);
    }
    if (DeckMixTimedOut(visual, now, timeoutSec)) return DeckMixClear(visual.flashUntil, YES);
    if (visual.phase == DeckMixPending || visual.phase == DeckMixBlending)
        return DeckMixClear(visual.flashUntil, NO);
    return visual;
}

const double kDeckSkipReplyTimeoutSec = 2;
const double kDeckSkipFlashSec = 0.15;
const double kDeckMixPollSec = 0.25;
const double kDeckPollSec = 1;

DeckMixVisual DeckMixVisualStep(DeckMixVisual current, DeckMixEvent event, double now,
                                GBDeckNow snapshot, double timeoutSec) {
    if (!isfinite(now)) return current;
    if (event == DeckMixEventBlend) {
        DeckMixVisual visual = {0};
        visual.phase = DeckMixArmed;
        visual.requested = YES;
        visual.since = now;
        return visual;
    }
    if (event == DeckMixEventCut) {
        if (current.phase == DeckMixArmed) current = DeckMixClear(0, NO);
        current.flashUntil = now + kDeckSkipFlashSec;
        current.failed = NO;
        return current;
    }
    if (event == DeckMixEventReply) {
        if (!snapshot.valid || !snapshot.ok) return DeckMixClear(current.flashUntil, YES);
        current.replySeen = YES;
        current.failed = NO;
        return DeckMixApplySnapshot(current, event, now, snapshot, timeoutSec);
    }
    if (event == DeckMixEventClock || event == DeckMixEventNone) {
        if (DeckMixTimedOut(current, now, timeoutSec)) return DeckMixClear(current.flashUntil, YES);
        return current;
    }
    if (event == DeckMixEventSnapshot)
        return DeckMixApplySnapshot(current, event, now, snapshot, timeoutSec);
    return current;
}

DeckMixTint DeckMixTintFor(DeckMixVisual visual, BOOL blendPresent,
                           BOOL blendManualKnown, BOOL blendManual) {
    if (visual.failed || visual.phase == DeckMixIdle) return DeckMixTintOff;
    if (visual.phase == DeckMixBlending) {
        if (blendPresent && blendManualKnown && !blendManual) return DeckMixTintSecondary;
        if (blendPresent && !blendManualKnown && !visual.requested) return DeckMixTintSecondary;
        return DeckMixTintAccent;
    }
    if (visual.phase == DeckMixPending && !visual.requested) return DeckMixTintSecondary;
    return DeckMixTintAccent;
}

BOOL DeckMixFlashActive(DeckMixVisual visual, double now) {
    return isfinite(now) && isfinite(visual.flashUntil) && visual.flashUntil > now;
}

DeckMixTint DeckMixShownTint(DeckMixVisual visual, double now, BOOL blendPresent,
                             BOOL blendManualKnown, BOOL blendManual) {
    DeckMixTint resting = DeckMixTintFor(visual, blendPresent, blendManualKnown, blendManual);
    if (!DeckMixFlashActive(visual, now)) return resting;
    return resting == DeckMixTintAccent ? DeckMixTintOff : DeckMixTintAccent;
}

double DeckNowPollInterval(BOOL popoverShown, DeckMixPhase phase) {
    if (popoverShown && (phase == DeckMixPending || phase == DeckMixBlending)) return kDeckMixPollSec;
    return kDeckPollSec;
}

NSString *DeckMixCountdownText(double secondsRemaining) {
    if (!isfinite(secondsRemaining) || secondsRemaining < 0) return nil;
    int whole = (int)floor(secondsRemaining + 1e-9);
    if (whole < 0) whole = 0;
    int hours = whole / 3600;
    int minutes = (whole % 3600) / 60;
    int seconds = whole % 60;
    if (hours > 0) return [NSString stringWithFormat:@"mix %d:%02d:%02d", hours, minutes, seconds];
    return [NSString stringWithFormat:@"mix %d:%02d", minutes, seconds];
}

NSString *DeckMixProgressText(double progress) {
    if (!isfinite(progress) || progress < 0 || progress >= 1) return nil;
    int percent = (int)lround(progress * 100.0);
    if (percent < 0) percent = 0;
    if (percent > 99) percent = 99;
    return [NSString stringWithFormat:@"mix %d%%", percent];
}

double DeckMixTickFraction(double position, double startsInS, double duration) {
    if (!isfinite(position) || !isfinite(startsInS) || !isfinite(duration) || duration <= 0) return NAN;
    if (position < 0) position = 0;
    if (startsInS < 0) startsInS = 0;
    double fraction = (position + startsInS) / duration;
    if (fraction < 0) fraction = 0;
    if (fraction > 1) fraction = 1;
    return fraction;
}

double DeckMixCountdownRemaining(double startsInS, double sampledAt, double now) {
    if (!isfinite(startsInS)) return NAN;
    if (startsInS < 0) startsInS = 0;
    if (!(sampledAt > 0) || !isfinite(sampledAt) || !isfinite(now)) return startsInS;
    double left = startsInS - (now - sampledAt);
    if (left < 0) left = 0;
    return left;
}

double DeckMixShownProgress(double progress, double lengthS, double sampledAt, double now) {
    if (!isfinite(progress)) return NAN;
    if (progress < 0) progress = 0;
    if (progress >= 1) return 1;
    if (!(sampledAt > 0) || !isfinite(sampledAt) || !isfinite(now) || !isfinite(lengthS) ||
        !(lengthS > 0) || now < sampledAt)
        return progress;
    double shown = progress + (now - sampledAt) / lengthS;
    if (shown < 0) shown = 0;
    if (shown >= 1) shown = 0.999;
    return shown;
}

NSString *DeckSkipFailureTip(NSString *error) {
    NSString *trimmed = [error isKindOfClass:NSString.class]
        ? [error stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    if (!trimmed.length) return @"Skip failed";
    if (trimmed.length > 80) trimmed = [trimmed substringToIndex:80];
    return [NSString stringWithFormat:@"Skip failed — %@", trimmed];
}

GBDeckNow DeckNowFromJSON(NSData *json) {
    GBDeckNow out = DeckNowEmpty();
    if (![json isKindOfClass:NSData.class] || json.length == 0) return out;
    id obj = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (![obj isKindOfClass:NSDictionary.class]) return out;
    out.valid = YES;
    id okValue = obj[@"ok"];
    if (okValue) out.ok = [okValue isKindOfClass:NSNumber.class] && [okValue boolValue];
    else out.ok = YES;

    NSString *state = [obj[@"state"] isKindOfClass:NSString.class] ? [obj[@"state"] lowercaseString] : @"";
    state = [state stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    DeckCopyField(out.state, sizeof(out.state), state);
    out.playing = [state isEqual:@"playing"];
    out.paused = [state isEqual:@"paused"];
    out.stopped = [state isEqual:@"stopped"];

    NSDictionary *track = [obj[@"track"] isKindOfClass:NSDictionary.class] ? obj[@"track"] : nil;
    NSDictionary *next = [obj[@"next"] isKindOfClass:NSDictionary.class] ? obj[@"next"] : nil;
    DeckCopyField(out.title, sizeof(out.title), track[@"title"]);
    DeckCopyField(out.artist, sizeof(out.artist), track[@"artist"]);
    DeckCopyField(out.path, sizeof(out.path), track[@"path"]);
    DeckCopyField(out.nextTitle, sizeof(out.nextTitle), next[@"title"]);

    double position = DeckJSONNumber(obj[@"position_s"]);
    if (isfinite(position) && position < 0) position = 0;
    out.position = isfinite(position) ? position : NAN;
    double left = DeckJSONNumber(obj[@"track_left_s"]);
    if (isfinite(position) && isfinite(left) && left >= 0) out.duration = position + left;
    else {
        double listed = DeckJSONNumber(track[@"duration_s"]);
        if (!isfinite(listed)) listed = DeckJSONNumber(obj[@"duration_s"]);
        out.duration = (isfinite(listed) && listed > 0) ? listed : NAN;
    }
    double effective = DeckJSONNumber(obj[@"effective_bpm"]);
    double trackBPM = DeckJSONNumber(track[@"bpm"]);
    if (isfinite(effective) && effective > 0) out.bpm = effective;
    else if (isfinite(trackBPM) && trackBPM > 0) out.bpm = trackBPM;

    DeckCopyField(out.error, sizeof(out.error), obj[@"error"]);
    id immediate = obj[@"immediate"];
    if ([immediate isKindOfClass:NSNumber.class]) out.immediate = [immediate boolValue];

    NSDictionary *pending = [obj[@"pending_skip"] isKindOfClass:NSDictionary.class] ? obj[@"pending_skip"] : nil;
    if (pending) {
        out.pending.present = YES;
        DeckCopyField(out.pending.mode, sizeof(out.pending.mode), pending[@"mode"]);
        DeckCopyField(out.pending.requestedAt, sizeof(out.pending.requestedAt), pending[@"requested_at"]);
        double starts = DeckJSONNumber(pending[@"starts_in_s"]);
        if (isfinite(starts) && starts < 0) starts = 0;
        out.pending.startsInS = isfinite(starts) ? starts : NAN;
        double bars = DeckJSONNumber(pending[@"bars"]);
        out.pending.bars = isfinite(bars) ? bars : NAN;
    }
    NSDictionary *blend = [obj[@"blend"] isKindOfClass:NSDictionary.class] ? obj[@"blend"] : nil;
    if (blend) {
        out.blend.present = YES;
        DeckCopyField(out.blend.type, sizeof(out.blend.type), blend[@"type"]);
        id manual = blend[@"manual"];
        if ([manual isKindOfClass:NSNumber.class]) {
            out.blend.manualKnown = YES;
            out.blend.manual = [manual boolValue];
        }
        double progress = DeckJSONNumber(blend[@"progress"]);
        if (isfinite(progress)) {
            if (progress < 0) progress = 0;
            if (progress > 1) progress = 1;
            out.blend.progress = progress;
        }
        double elapsed = DeckJSONNumber(blend[@"elapsed_s"]);
        out.blend.elapsedS = isfinite(elapsed) ? elapsed : NAN;
        double length = DeckJSONNumber(blend[@"length_s"]);
        out.blend.lengthS = isfinite(length) ? length : NAN;
        NSDictionary *incoming = [blend[@"incoming"] isKindOfClass:NSDictionary.class] ? blend[@"incoming"] : nil;
        DeckCopyField(out.blend.title, sizeof(out.blend.title), incoming[@"title"]);
        DeckCopyField(out.blend.artist, sizeof(out.blend.artist), incoming[@"artist"]);
        DeckCopyField(out.blend.path, sizeof(out.blend.path), incoming[@"path"]);
        DeckCopyField(out.blend.key, sizeof(out.blend.key), incoming[@"key"]);
        double bpm = DeckJSONNumber(incoming[@"bpm"]);
        out.blend.bpm = (isfinite(bpm) && bpm > 0) ? bpm : NAN;
    }
    return out;
}

NSString *SelectorDJPath(NSString *appBundle, NSString *buildRoot) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL dir = NO;
    if ([appBundle isKindOfClass:NSString.class] && appBundle.length &&
        [fm fileExistsAtPath:appBundle isDirectory:&dir] && dir)
        return appBundle;
    if (![buildRoot isKindOfClass:NSString.class] || !buildRoot.length ||
        ![fm fileExistsAtPath:buildRoot isDirectory:&dir] || !dir)
        return nil;
    for (NSString *rel in @[@"debug/SelectorApp", @"out/Products/Debug/SelectorApp"]) {
        NSString *path = [buildRoot stringByAppendingPathComponent:rel];
        if ([fm isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

NSString *SeedCaption(NSString *title) {
    NSString *t = title ?: @"";
    for (NSString *pattern in @[@"\\s*[\\(\\[][^\\)\\]]*(feat\\.?|ft\\.?|with|remaster|version|edit|mix|live|deluxe|edition)[^\\)\\]]*[\\)\\]]",
                                @"\\s+-\\s+(single|ep)$", @"\\s+(ep)$"]) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
        t = [re stringByReplacingMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@""];
    }
    t = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return t.length ? t : (title ?: @"");
}

NSString *RemoteAwayText(double secondsSinceLastSample) {
    if (secondsSinceLastSample <= 0) return @"away";
    if (secondsSinceLastSample < 3600) {
        int minutes = (int)floor(secondsSinceLastSample / 60.0);
        if (minutes < 2) minutes = 2;
        return [NSString stringWithFormat:@"away %dm", minutes];
    }
    if (secondsSinceLastSample < 86400) {
        double hours = secondsSinceLastSample / 3600.0;
        if (hours < 10) {
            int tenths = (int)lround(hours * 10);
            if (tenths % 10 == 0) return [NSString stringWithFormat:@"away %dh", tenths / 10];
            return [NSString stringWithFormat:@"away %d.%dh", tenths / 10, tenths % 10];
        }
        return [NSString stringWithFormat:@"away %dh", (int)floor(hours)];
    }
    return [NSString stringWithFormat:@"away %dd", (int)floor(secondsSinceLastSample / 86400.0)];
}

NSNumber *SampleNumber(id value) {
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

NSString *SampleString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static double SampleFactorClamp(double headroom) {
    return MIN(1, MAX(0, headroom));
}

NSInteger HeavySlotCounts(NSString *status, NSInteger *freeSlots) {
    NSInteger slots = 0, free = 0;
    for (NSString *l in [status ?: @"" componentsSeparatedByString:@"\n"]) {
        if (![l hasPrefix:@"slot "]) continue;
        if ([l rangeOfString:@": off ("].location != NSNotFound) continue;
        slots++;
        if ([l hasSuffix:@": free"]) free++;
    }
    if (freeSlots) *freeSlots = free;
    return slots;
}

NSDictionary *WorkerReadiness(NSDictionary *sample, NSString *mode, NSInteger freeSlots, NSInteger slots) {
    NSMutableArray *factors = [NSMutableArray array];   // @[headroom, label]
    NSNumber *cpu = SampleNumber(sample[@"cpu"]);
    if (cpu) [factors addObject:@[@(SampleFactorClamp(1 - cpu.doubleValue / 100)), @"CPU busy"]];
    NSString *thermal = SampleString(sample[@"thermal"]);
    if (thermal && ![thermal isEqual:@"nominal"]) {
        double heat = [thermal isEqual:@"moderate"] ? 0.6 : 0.4;
        NSNumber *topN = SampleNumber(sample[@"pTopMHz"]), *mhzN = SampleNumber(sample[@"pMHz"]), *busyN = SampleNumber(sample[@"pBusy"]);
        double top = topN.doubleValue, mhz = mhzN.doubleValue;
        if (![thermal isEqual:@"moderate"] && busyN && busyN.doubleValue >= 0.5 && top > 0 && mhz > 0) heat = MIN(0.6, mhz / top);
        [factors addObject:@[@(SampleFactorClamp(heat)), @"hot"]];
    }
    NSString *mem = SampleString(sample[@"memPressure"]);
    if ([mem isEqual:@"High"]) [factors addObject:@[@0.2, @"low memory"]];
    else if ([mem isEqual:@"Medium"]) [factors addObject:@[@0.55, @"low memory"]];
    NSNumber *freeN = SampleNumber(sample[@"diskFreeGB"]), *totalN = SampleNumber(sample[@"diskTotalGB"]);
    // Absolute space, not a share: a job needs gigabytes, and 48 GB free on a 512 GB disk is plenty.
    // Limits from 40 GB down; under 10 GB it is the main limit.
    if (freeN && totalN && totalN.doubleValue > 0)
        [factors addObject:@[@(SampleFactorClamp(freeN.doubleValue / 50)), @"disk low"]];
    NSNumber *batt = SampleNumber(sample[@"batt"]), *ac = SampleNumber(sample[@"ac"]);
    if (batt && !(ac ? ac.boolValue : NO))
        [factors addObject:@[@(SampleFactorClamp(MIN(1, batt.doubleValue / 50))), @"low battery"]];
    if (slots > 0) {
        double slotHead = freeSlots <= 0 ? 0.2 : MIN(1, 0.4 + 0.6 * freeSlots / (double)slots);
        [factors addObject:@[@(SampleFactorClamp(slotHead)), @"slots full"]];
    }
    if ([mode isEqual:@"gentle"]) [factors addObject:@[@0.3, @"in use"]];
    double score = 1; NSString *limit = @"ready";
    for (NSArray *f in factors) if ([f[0] doubleValue] < score) { score = [f[0] doubleValue]; limit = f[1]; }
    score = SampleFactorClamp(score);
    if (score >= 0.8) limit = @"ready";
    return @{@"score": @(score), @"limit": limit};
}

static NSString *FleetTrim(id value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *FleetShortSHA(NSString *sha) {
    return sha.length > 7 ? [sha substringToIndex:7] : (sha ?: @"");
}

// A 7-character prefix is the same commit as the full sha `git rev-parse` writes.
static BOOL FleetSHAEqual(NSString *a, NSString *b) {
    if (!a.length || !b.length) return NO;
    if ([a isEqualToString:b]) return YES;
    return a.length >= 7 && b.length >= 7 && ([a hasPrefix:b] || [b hasPrefix:a]);
}

static NSString *FleetStateWord(NSString *state) {
    if ([state isEqual:@"no-release"]) return @"no release";
    if ([state isEqual:@"local-changes"]) return @"local edits";
    if ([state isEqual:@"not-main"]) return @"not main";
    if ([state isEqual:@"fetch-failed"]) return @"fetch failed";
    if ([state isEqual:@"install-failed"]) return @"install failed";
    return nil;
}

NSDictionary *FleetSyncDrift(NSString *statusJSON, NSString *localSHA) {
    NSString *text = FleetTrim(statusJSON);
    if (!text.length) return nil;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    id obj = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![obj isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *status = obj;
    NSString *state = FleetTrim(status[@"state"]);
    NSString *installed = FleetTrim(status[@"installed"]);
    NSString *detail = FleetTrim(status[@"detail"]);
    NSString *local = FleetTrim(localSHA);
    NSInteger behind = -1;
    if ([status[@"behind"] isKindOfClass:NSNumber.class]) behind = [status[@"behind"] integerValue];
    NSString *word = state.length && ![state isEqual:@"ok"] ? FleetStateWord(state) : nil;
    if (!word.length && behind > 0) word = [NSString stringWithFormat:@"%ld behind", (long)behind];
    if (!word.length && installed.length && local.length && !FleetSHAEqual(installed, local)) word = @"differs";
    if (!word.length) return nil;
    if (!detail.length) {
        if ([word isEqual:@"differs"])
            detail = [NSString stringWithFormat:@"installed %@ · this Mac %@", FleetShortSHA(installed), FleetShortSHA(local)];
        else detail = word;
    }
    if (behind > 0 && [detail rangeOfString:@"behind"].location == NSNotFound)
        detail = [NSString stringWithFormat:@"%@ · %ld behind", detail, (long)behind];
    return @{@"word": word, @"detail": detail};
}

