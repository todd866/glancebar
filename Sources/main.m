// Glancebar — one configurable menu bar item at a glance. Click for a native popover
// with storage, battery, system, and AI summaries plus a deeper details window.
// Single-file Objective-C/AppKit. Zero dependencies, no sudo. Pure logic in pure.{h,m}.
#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <libproc.h>
#import <mach/mach.h>
#import <sys/mount.h>
#import <sys/sysctl.h>
#import "pure.h"

#pragma mark - Disk

@interface Volume : NSObject
@property (copy) NSString *path, *name;
@property long long total, available;
@property BOOL isInternal;
@end
@implementation Volume
- (long long)used { return MAX(0LL, self.total - self.available); }
- (double)fraction { return self.total > 0 ? (double)self.used / self.total : 0; }
@end

static NSString *FmtBytes(long long b) {
    return [NSByteCountFormatter stringFromByteCount:b countStyle:NSByteCountFormatterCountStyleFile];
}

static Volume *VolumeFromURL(NSURL *url, NSArray *keys) {
    NSDictionary *v = [url resourceValuesForKeys:keys error:nil];
    NSNumber *total = v[NSURLVolumeTotalCapacityKey];
    NSString *name = v[NSURLVolumeNameKey];
    if (total.longLongValue <= 0) return nil;

    long long avail = [v[NSURLVolumeAvailableCapacityKey] longLongValue];
    NSNumber *important = [url resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey]
                                               error:nil][NSURLVolumeAvailableCapacityForImportantUsageKey];
    if (important.longLongValue > 0) avail = important.longLongValue;

    Volume *vol = [Volume new];
    vol.path = url.path.length ? url.path : @"/";
    vol.name = name.length ? name : [NSFileManager.defaultManager displayNameAtPath:vol.path];
    if (!vol.name.length) vol.name = vol.path;
    vol.total = total.longLongValue; vol.available = avail;
    vol.isInternal = [v[NSURLVolumeIsInternalKey] boolValue] || [vol.path isEqualToString:@"/"];
    return vol;
}

static Volume *RootVolumeFallback(void) {
    NSURL *root = [NSURL fileURLWithPath:@"/" isDirectory:YES];
    NSArray *keys = @[NSURLVolumeNameKey, NSURLVolumeTotalCapacityKey,
                      NSURLVolumeAvailableCapacityKey, NSURLVolumeIsInternalKey];
    Volume *fromURL = VolumeFromURL(root, keys);
    if (fromURL) return fromURL;

    struct statfs s;
    if (statfs("/", &s) != 0 || s.f_blocks <= 0) return nil;
    Volume *vol = [Volume new];
    vol.path = @"/";
    NSString *displayName = [NSFileManager.defaultManager displayNameAtPath:@"/"];
    vol.name = displayName.length ? displayName : @"Macintosh HD";
    vol.total = (long long)s.f_blocks * (long long)s.f_bsize;
    vol.available = (long long)s.f_bavail * (long long)s.f_bsize;
    vol.isInternal = YES;
    return vol;
}

static NSArray<Volume *> *ScanVolumes(void) {
    NSArray *keys = @[NSURLVolumeNameKey, NSURLVolumeTotalCapacityKey,
                      NSURLVolumeAvailableCapacityKey, NSURLVolumeIsInternalKey];
    NSArray<NSURL *> *urls = [NSFileManager.defaultManager
        mountedVolumeURLsIncludingResourceValuesForKeys:keys
                                                options:NSVolumeEnumerationSkipHiddenVolumes];
    NSMutableArray<Volume *> *found = [NSMutableArray array];
    BOOL hasRoot = NO;
    for (NSURL *url in urls) {
        Volume *vol = VolumeFromURL(url, keys);
        if (!vol) continue;
        if ([vol.path isEqualToString:@"/"]) hasRoot = YES;
        [found addObject:vol];
    }
    if (!hasRoot) {
        Volume *root = RootVolumeFallback();
        if (root) [found addObject:root];
    }
    [found sortUsingComparator:^NSComparisonResult(Volume *a, Volume *b) {
        BOOL ar = [a.path isEqualToString:@"/"], br = [b.path isEqualToString:@"/"];
        if (ar != br) return ar ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedStandardCompare:b.name];
    }];
    return found;
}

#pragma mark - Battery

static long NumFor(NSDictionary *d, NSString *k) {
    id v = d[k]; return [v isKindOfClass:NSNumber.class] ? [v longValue] : LONG_MIN;
}

static BatteryState ReadBattery(void) {
    BatteryState b = {0};
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!svc) return b;
    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS) {
        NSDictionary *d = CFBridgingRelease(props);
        b.valid = YES;
        b.percent = (int)NumFor(d, @"CurrentCapacity");
        b.isCharging = [d[@"IsCharging"] boolValue];
        b.acConnected = [d[@"ExternalConnected"] boolValue];
        b.fullyCharged = [d[@"FullyCharged"] boolValue];
        b.rawCurrent_mAh = NumFor(d, @"AppleRawCurrentCapacity");
        b.rawMax_mAh = NumFor(d, @"AppleRawMaxCapacity");
        b.designCap_mAh = NumFor(d, @"DesignCapacity");
        long amp = NumFor(d, @"Amperage");
        if (amp == LONG_MIN) amp = NumFor(d, @"InstantAmperage");
        if (amp > (1L << 40)) amp -= (1L << 48);
        b.amperage_mA = amp == LONG_MIN ? 0 : amp;
        b.voltage_mV = NumFor(d, @"Voltage");
        b.cycleCount = NumFor(d, @"CycleCount");
        long tr = NumFor(d, @"TimeRemaining");
        b.minutesToEmpty = (tr == LONG_MIN || tr >= 65535) ? -1 : tr;
    }
    IOObjectRelease(svc);
    return b;
}

#pragma mark - Process metrics

static NSString *AppGroupForPid(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
    NSString *p = [NSString stringWithUTF8String:path];
    NSRange app = [p rangeOfString:@".app/"];
    if (app.location == NSNotFound) return nil;
    NSString *bundle = [p substringToIndex:app.location + 4];
    NSString *name = [NSFileManager.defaultManager displayNameAtPath:bundle];
    if ([name hasSuffix:@".app"]) name = [name substringToIndex:name.length - 4];
    return name.length ? name : nil;
}

static NSString *RunTaskOutput(NSString *path, NSArray<NSString *> *args) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:path];
    t.arguments = args;
    t.environment = @{@"LC_ALL": @"C"};   // ps/top honor LC_NUMERIC; force '.' decimals
    NSPipe *pipe = [NSPipe pipe]; t.standardOutput = pipe;
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![t launchAndReturnError:nil]) return nil;
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSArray<NSDictionary *> *SampleHogs(int topN) {
    NSString *out = RunTaskOutput(@"/usr/bin/top", @[@"-l", @"2", @"-s", @"1", @"-stats",
                                                     @"pid,command,power", @"-o", @"power", @"-n", @"40"]);
    return ParseHogs(out ? out : @"", topN, ^NSString *(pid_t pid){ return AppGroupForPid(pid); });
}

static NSDictionary<NSString *, NSArray<NSDictionary *> *> *SampleProcessStats(int topN) {
    NSString *out = RunTaskOutput(@"/bin/ps", @[@"-axo", @"pid=,pcpu=,rss=,comm="]);
    return ParseProcessStats(out ? out : @"", topN, ^NSString *(pid_t pid){ return AppGroupForPid(pid); });
}

static NSArray<NSString *> *CommandsForHog(NSDictionary *h) {
    id commands = h[@"commands"];
    return [commands isKindOfClass:NSArray.class] ? commands : @[];
}

static NSString *CommandSummary(NSArray<NSString *> *commands) {
    if (!commands.count) return @"process";
    if (commands.count == 1) return [NSString stringWithFormat:@"%@ process", commands.firstObject];
    if (commands.count == 2) return [NSString stringWithFormat:@"%@ + %@", commands[0], commands[1]];
    return [NSString stringWithFormat:@"%@ + %@ + %lu more",
            commands[0], commands[1], (unsigned long)commands.count - 2];
}

static NSDictionary *KnownProcessInfo(NSString *name) {
    static NSDictionary *known;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        known = @{
            @"WindowServer": @{@"title": @"Display Server", @"detail": @"WindowServer · macOS display compositor"},
            @"syspolicyd": @{@"title": @"System Policy", @"detail": @"syspolicyd · app security checks"},
            @"trustd": @{@"title": @"Certificate Trust", @"detail": @"trustd · certificate checks"},
            @"securityd": @{@"title": @"Security Service", @"detail": @"securityd · keychain and authorization"},
            @"kernel_task": @{@"title": @"Kernel", @"detail": @"kernel_task · macOS core system work"},
            @"launchservicesd": @{@"title": @"Launch Services", @"detail": @"launchservicesd · app launch database"},
            @"cfprefsd": @{@"title": @"Preferences Service", @"detail": @"cfprefsd · app settings cache"},
            @"distnoted": @{@"title": @"Notifications", @"detail": @"distnoted · system notification routing"},
            @"logd": @{@"title": @"Logging", @"detail": @"logd · system log service"},
            @"runningboardd": @{@"title": @"App Lifecycle", @"detail": @"runningboardd · app state management"},
            @"sysmond": @{@"title": @"System Monitor", @"detail": @"sysmond · system activity tracking"},
            @"mds": @{@"title": @"Spotlight", @"detail": @"mds · search indexing"},
            @"mds_stores": @{@"title": @"Spotlight", @"detail": @"mds_stores · search index database"},
            @"mdworker_shared": @{@"title": @"Spotlight Worker", @"detail": @"mdworker_shared · file indexing"},
            @"backupd": @{@"title": @"Time Machine", @"detail": @"backupd · backup service"},
            @"cloudd": @{@"title": @"iCloud", @"detail": @"cloudd · iCloud sync"},
            @"nsurlsessiond": @{@"title": @"Background Transfers", @"detail": @"nsurlsessiond · downloads and uploads"},
            @"locationd": @{@"title": @"Location Services", @"detail": @"locationd · location access"},
            @"bluetoothd": @{@"title": @"Bluetooth", @"detail": @"bluetoothd · Bluetooth service"},
            @"airportd": @{@"title": @"Wi-Fi", @"detail": @"airportd · wireless networking"},
            @"mediaanalysisd": @{@"title": @"Media Analysis", @"detail": @"mediaanalysisd · photo and media analysis"}
        };
    });
    return known[name];
}

static NSDictionary *ProcessDisplayInfo(NSDictionary *h) {
    NSString *name = [h[@"name"] isKindOfClass:NSString.class] ? h[@"name"] : @"Process";
    NSDictionary *known = KnownProcessInfo(name);
    if (known) return known;

    NSArray<NSString *> *commands = CommandsForHog(h);
    NSString *detail = CommandSummary(commands);
    if (commands.count == 1 && [commands.firstObject isEqualToString:name])
        detail = [name hasSuffix:@"d"] ? @"background service" : @"process";
    return @{@"title": name, @"detail": detail};
}

static NSString *PressureLevel(double share) {
    return share >= 0.35 ? @"High" : share >= 0.15 ? @"Medium" : @"Low";
}

static NSColor *PressureColor(double share) {
    if (share >= 0.35) return NSColor.systemOrangeColor;
    if (share >= 0.15) return [NSColor.systemYellowColor colorWithAlphaComponent:0.9];
    return [NSColor.systemGreenColor colorWithAlphaComponent:0.85];
}

#pragma mark - System pressure

typedef struct {
    BOOL valid;
    uint64_t user, system, idle, nice;
} CPUCounters;

typedef struct {
    BOOL cpuValid, memValid, swapValid;
    double cpu;
    uint64_t memTotal, memUsed, memAvailable, swapUsed;
} SystemState;

static CPUCounters ReadCPUCounters(void) {
    CPUCounters c = {0};
    natural_t cpuCount = 0;
    processor_info_array_t cpuInfo = NULL;
    mach_msg_type_number_t cpuInfoCount = 0;
    kern_return_t kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                           &cpuCount, &cpuInfo, &cpuInfoCount);
    if (kr != KERN_SUCCESS || !cpuInfo) return c;
    processor_cpu_load_info_t loads = (processor_cpu_load_info_t)cpuInfo;
    for (natural_t i = 0; i < cpuCount; i++) {
        c.user += loads[i].cpu_ticks[CPU_STATE_USER];
        c.system += loads[i].cpu_ticks[CPU_STATE_SYSTEM];
        c.idle += loads[i].cpu_ticks[CPU_STATE_IDLE];
        c.nice += loads[i].cpu_ticks[CPU_STATE_NICE];
    }
    vm_deallocate(mach_task_self(), (vm_address_t)cpuInfo, cpuInfoCount * sizeof(integer_t));
    c.valid = YES;
    return c;
}

static SystemState ReadSystemState(CPUCounters *previous) {
    SystemState s = {0};

    CPUCounters now = ReadCPUCounters();
    if (now.valid && previous && previous->valid) {
        uint64_t busy = (now.user - previous->user) + (now.system - previous->system) + (now.nice - previous->nice);
        uint64_t idle = now.idle - previous->idle;
        uint64_t total = busy + idle;
        if (total > 0) { s.cpu = (double)busy / (double)total; s.cpuValid = YES; }
    }
    if (previous && now.valid) *previous = now;

    uint64_t memTotal = 0;
    size_t memSize = sizeof(memTotal);
    if (sysctlbyname("hw.memsize", &memTotal, &memSize, NULL, 0) == 0 && memTotal > 0) {
        vm_size_t pageSize = 0;
        vm_statistics64_data_t vm = {0};
        mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
        if (host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS &&
            host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS) {
            uint64_t usedPages = (uint64_t)vm.active_count + vm.wire_count + vm.compressor_page_count;
            uint64_t used = usedPages * (uint64_t)pageSize;
            if (used > memTotal) used = memTotal;
            s.memTotal = memTotal;
            s.memUsed = used;
            s.memAvailable = memTotal - used;
            s.memValid = YES;
        }
    }

    struct xsw_usage swap = {0};
    size_t swapSize = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &swapSize, NULL, 0) == 0) {
        s.swapUsed = swap.xsu_used;
        s.swapValid = YES;
    }

    return s;
}

static NSString *MemoryPressureLevel(SystemState s) {
    if (!s.memValid || s.memTotal == 0) return @"Unknown";
    double available = (double)s.memAvailable / (double)s.memTotal;
    if (available < 0.08 || (s.swapValid && s.swapUsed >= 2ULL * 1024ULL * 1024ULL * 1024ULL)) return @"High";
    if (available < 0.16 || (s.swapValid && s.swapUsed >= 512ULL * 1024ULL * 1024ULL)) return @"Medium";
    return @"Low";
}

static NSString *SystemPressureLevel(SystemState s) {
    NSString *mem = MemoryPressureLevel(s);
    if ([mem isEqualToString:@"High"] || (s.cpuValid && s.cpu >= 0.85)) return @"High";
    if ([mem isEqualToString:@"Medium"] || (s.cpuValid && s.cpu >= 0.50)) return @"Medium";
    if ([mem isEqualToString:@"Unknown"] && !s.cpuValid) return @"Unknown";
    return @"Low";
}

static NSColor *SystemPressureColor(NSString *level) {
    if ([level isEqualToString:@"High"]) return NSColor.systemRedColor;
    if ([level isEqualToString:@"Medium"]) return NSColor.systemOrangeColor;
    if ([level isEqualToString:@"Unknown"]) return NSColor.secondaryLabelColor;
    return NSColor.systemGreenColor;
}

static NSString *CPUStatusText(SystemState s) {
    return s.cpuValid ? [NSString stringWithFormat:@"CPU %d%%", (int)lround(s.cpu * 100)] : @"CPU estimating";
}

static NSString *MemoryStatusText(SystemState s) {
    if (!s.memValid) return @"Memory unknown";
    return [NSString stringWithFormat:@"Memory %@ · %@ available", MemoryPressureLevel(s), FmtBytes(s.memAvailable)];
}

static NSString *SwapStatusText(SystemState s) {
    if (!s.swapValid) return @"Swap unknown";
    return [NSString stringWithFormat:@"Swap %@", FmtBytes(s.swapUsed)];
}

static NSString *SystemSummaryText(SystemState s) {
    return [NSString stringWithFormat:@"%@ · %@ · %@",
            CPUStatusText(s), MemoryStatusText(s), SwapStatusText(s)];
}

static NSColor *CPUColor(double cpu) {
    if (cpu >= 0.80) return NSColor.systemRedColor;
    if (cpu >= 0.50) return NSColor.systemOrangeColor;
    if (cpu >= 0.20) return [NSColor.systemYellowColor colorWithAlphaComponent:0.9];
    return [NSColor.systemGreenColor colorWithAlphaComponent:0.85];
}

#pragma mark - AI usage

@interface AIUsage : NSObject
@property (copy) NSString *name, *source, *resetText, *statusText, *statusSource, *statusReason, *topModel;
@property BOOL available, stale, limitStatusAvailable;
@property double remainingFraction;
@property long long todayTokens, weekTokens, todayMessages, todaySessions, todayToolCalls, weekSessions;
@property (strong) NSDate *lastActivity;
@property (copy) NSArray<NSDictionary *> *models;
@end
@implementation AIUsage @end

static NSString *FmtCompact(long long n) {
    double v = (double)llabs(n);
    NSString *sign = n < 0 ? @"-" : @"";
    if (v >= 1000000000.0) return [NSString stringWithFormat:@"%@%.1fB", sign, v / 1000000000.0];
    if (v >= 1000000.0) return [NSString stringWithFormat:@"%@%.1fM", sign, v / 1000000.0];
    if (v >= 1000.0) return [NSString stringWithFormat:@"%@%.0fK", sign, v / 1000.0];
    return [NSString stringWithFormat:@"%lld", n];
}

static NSString *FmtTokenCount(long long tokens) {
    return [NSString stringWithFormat:@"%@ tokens", FmtCompact(tokens)];
}

static NSDateFormatter *DateOnlyFormatter(void) {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.dateFormat = @"yyyy-MM-dd";
    });
    return fmt;
}

static NSDate *StartOfLocalDay(NSDate *date) {
    return [NSCalendar.currentCalendar startOfDayForDate:date ?: NSDate.date];
}

static NSString *LocalDateString(NSDate *date) {
    return [DateOnlyFormatter() stringFromDate:date ?: NSDate.date];
}

static NSString *ShortDateText(NSString *yyyyMMdd) {
    NSDate *date = [DateOnlyFormatter() dateFromString:yyyyMMdd ?: @""];
    if (!date) return yyyyMMdd ?: @"unknown";
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"MMM d";
    return [fmt stringFromDate:date];
}

static NSString *ClockText(NSDate *date) {
    if (!date) return @"unknown";
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.timeStyle = NSDateFormatterShortStyle;
    fmt.dateStyle = NSDateFormatterNoStyle;
    return [fmt stringFromDate:date];
}

static NSString *ResetTextFromDate(NSDate *date) {
    if (!date) return nil;
    NSDateFormatter *fmt = [NSDateFormatter new];
    BOOL today = [NSCalendar.currentCalendar isDate:date inSameDayAsDate:NSDate.date];
    fmt.dateStyle = today ? NSDateFormatterNoStyle : NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    return [NSString stringWithFormat:@"Reset %@", [fmt stringFromDate:date]];
}

static NSDictionary *JSONDictionaryAtPath(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (!data.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static long long SumNumbersInDictionary(NSDictionary *d) {
    long long total = 0;
    for (id v in d.allValues) if ([v isKindOfClass:NSNumber.class]) total += [v longLongValue];
    return total;
}

static NSArray<NSDictionary *> *ModelRowsFromTokenDictionary(NSDictionary *tokensByModel) {
    if (![tokensByModel isKindOfClass:NSDictionary.class]) return @[];
    NSArray *keys = [tokensByModel keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [b compare:a];
    }];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *model in keys) {
        NSNumber *tokens = tokensByModel[model];
        if (![tokens isKindOfClass:NSNumber.class] || tokens.longLongValue <= 0) continue;
        [rows addObject:@{@"name": model, @"tokens": tokens}];
    }
    return rows;
}

static NSString *ShortModelName(NSString *model) {
    if (!model.length) return @"unknown";
    NSString *s = model;
    for (NSString *prefix in @[@"claude-", @"openai/"]) {
        if ([s hasPrefix:prefix]) s = [s substringFromIndex:prefix.length];
    }
    return s;
}

static AIUsage *UnavailableAIUsage(NSString *name, NSString *source) {
    AIUsage *u = [AIUsage new];
    u.name = name;
    u.source = source;
    u.remainingFraction = -1;
    u.resetText = @"Not exposed locally";
    u.statusText = @"Local state not found";
    u.statusReason = @"No limit status source";
    u.models = @[];
    return u;
}

static NSNumber *StatusNumberForKeys(NSDictionary *d, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id v = d[key];
        if ([v isKindOfClass:NSNumber.class]) return v;
        if ([v isKindOfClass:NSString.class]) {
            NSScanner *scanner = [NSScanner scannerWithString:v];
            double n = 0;
            if ([scanner scanDouble:&n]) return @(n);
        }
    }
    return nil;
}

static NSString *StatusStringForKeys(NSDictionary *d, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id v = d[key];
        if ([v isKindOfClass:NSString.class] && [v length]) return v;
    }
    return nil;
}

static NSDate *DateFromStatusString(NSString *s) {
    if (!s.length) return nil;
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    NSDate *date = [iso dateFromString:s];
    if (date) return date;

    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    for (NSString *format in @[@"yyyy-MM-dd HH:mm:ss ZZZZZ", @"yyyy-MM-dd HH:mm:ss", @"yyyy-MM-dd'T'HH:mm:ssZZZZZ"]) {
        fmt.dateFormat = format;
        date = [fmt dateFromString:s];
        if (date) return date;
    }
    return nil;
}

static NSDictionary *AIStatusEntry(NSDictionary *root, NSString *name) {
    if (![root isKindOfClass:NSDictionary.class] || !name.length) return nil;
    NSString *lower = name.lowercaseString;
    for (NSString *key in @[name, lower]) {
        id entry = root[key];
        if ([entry isKindOfClass:NSDictionary.class]) return entry;
    }
    NSDictionary *providers = [root[@"providers"] isKindOfClass:NSDictionary.class] ? root[@"providers"] : nil;
    if (providers) {
        for (NSString *key in @[name, lower]) {
            id entry = providers[key];
            if ([entry isKindOfClass:NSDictionary.class]) return entry;
        }
    }
    return nil;
}

static void ApplyAIStatusFile(AIUsage *u, NSDictionary *root, NSString *source) {
    NSDictionary *entry = AIStatusEntry(root, u.name);
    if (!entry) return;

    NSNumber *remaining = StatusNumberForKeys(entry, @[@"remainingFraction", @"remaining", @"fractionRemaining",
                                                       @"remainingPercent", @"percentRemaining", @"percentageRemaining"]);
    if (remaining) {
        double v = remaining.doubleValue;
        if (v > 1.0) v /= 100.0;
        u.remainingFraction = MIN(1.0, MAX(0.0, v));
        u.limitStatusAvailable = YES;
    }

    NSString *reset = StatusStringForKeys(entry, @[@"resetText", @"reset", @"resets"]);
    NSString *resetAt = StatusStringForKeys(entry, @[@"resetAt", @"resetTime", @"resetsAt"]);
    NSDate *resetDate = DateFromStatusString(resetAt);
    if (resetDate) reset = ResetTextFromDate(resetDate);
    if (reset.length) {
        u.resetText = reset;
        u.limitStatusAvailable = YES;
    }

    NSString *reason = StatusStringForKeys(entry, @[@"status", @"detail", @"reason"]);
    u.statusSource = source;
    u.statusReason = reason.length ? reason : @"Limit status from local status file";
}

static AIUsage *ReadClaudeUsage(void) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".claude/stats-cache.json"];
    NSDictionary *root = JSONDictionaryAtPath(path);
    if (!root) return UnavailableAIUsage(@"Claude", @"~/.claude/stats-cache.json");

    AIUsage *u = [AIUsage new];
    u.name = @"Claude";
    u.source = @"~/.claude/stats-cache.json";
    u.available = YES;
    u.remainingFraction = -1;
    u.resetText = @"Not exposed locally";
    u.statusReason = @"Claude's local stats cache does not expose limit remaining or reset time";

    NSDate *now = NSDate.date;
    NSDate *todayStart = StartOfLocalDay(now);
    NSDate *weekStart = [NSDate dateWithTimeInterval:-6 * 24 * 60 * 60 sinceDate:todayStart];
    NSString *today = LocalDateString(now);
    NSString *lastComputed = [root[@"lastComputedDate"] isKindOfClass:NSString.class] ? root[@"lastComputedDate"] : nil;
    u.stale = lastComputed.length && ![lastComputed isEqualToString:today];
    u.statusText = u.stale ? [NSString stringWithFormat:@"Stats through %@", ShortDateText(lastComputed)] : @"Local stats current";

    NSDictionary *latestTokensByModel = nil;
    NSString *latestDate = nil;
    for (NSDictionary *row in ([root[@"dailyModelTokens"] isKindOfClass:NSArray.class] ? root[@"dailyModelTokens"] : @[])) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *dateString = [row[@"date"] isKindOfClass:NSString.class] ? row[@"date"] : nil;
        NSDictionary *tokensByModel = [row[@"tokensByModel"] isKindOfClass:NSDictionary.class] ? row[@"tokensByModel"] : nil;
        NSDate *date = [DateOnlyFormatter() dateFromString:dateString ?: @""];
        if (!date || !tokensByModel) continue;
        if ([date compare:weekStart] != NSOrderedAscending && [date compare:now] != NSOrderedDescending)
            u.weekTokens += SumNumbersInDictionary(tokensByModel);
        if ([dateString isEqualToString:today])
            u.todayTokens = SumNumbersInDictionary(tokensByModel);
        if (!latestDate || [dateString compare:latestDate] == NSOrderedDescending) {
            latestDate = dateString;
            latestTokensByModel = tokensByModel;
        }
    }

    NSDictionary *displayTokens = nil;
    if (u.todayTokens > 0) {
        for (NSDictionary *row in ([root[@"dailyModelTokens"] isKindOfClass:NSArray.class] ? root[@"dailyModelTokens"] : @[])) {
            if ([row[@"date"] isEqualToString:today]) { displayTokens = row[@"tokensByModel"]; break; }
        }
    }
    if (!displayTokens) displayTokens = latestTokensByModel;
    u.models = ModelRowsFromTokenDictionary(displayTokens);
    if (u.models.count) u.topModel = u.models.firstObject[@"name"];

    for (NSDictionary *row in ([root[@"dailyActivity"] isKindOfClass:NSArray.class] ? root[@"dailyActivity"] : @[])) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *dateString = [row[@"date"] isKindOfClass:NSString.class] ? row[@"date"] : nil;
        NSDate *date = [DateOnlyFormatter() dateFromString:dateString ?: @""];
        if (!date) continue;
        if ([dateString isEqualToString:today]) {
            u.todayMessages = [row[@"messageCount"] longLongValue];
            u.todaySessions = [row[@"sessionCount"] longLongValue];
            u.todayToolCalls = [row[@"toolCallCount"] longLongValue];
        }
        if ([date compare:weekStart] != NSOrderedAscending && [date compare:now] != NSOrderedDescending)
            u.weekSessions += [row[@"sessionCount"] longLongValue];
    }

    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    NSDate *mtime = attrs[NSFileModificationDate];
    if (mtime) u.lastActivity = mtime;
    return u;
}

static NSArray<NSString *> *SQLiteFields(NSString *line) {
    if (!line.length) return @[];
    return [line componentsSeparatedByString:@"\t"];
}

static NSString *RunSQLite(NSString *path, NSString *sql) {
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    return RunTaskOutput(@"/usr/bin/sqlite3", @[@"-readonly", @"-separator", @"\t", path, sql]);
}

static AIUsage *ReadCodexUsage(void) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@".codex/state_5.sqlite"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path])
        return UnavailableAIUsage(@"Codex", @"~/.codex/state_5.sqlite");

    NSDate *todayStart = StartOfLocalDay(NSDate.date);
    long long todayEpoch = (long long)todayStart.timeIntervalSince1970;
    long long weekEpoch = todayEpoch - 6LL * 24LL * 60LL * 60LL;

    NSString *todaySQL = [NSString stringWithFormat:
        @"select count(*), coalesce(sum(tokens_used),0), coalesce(max(updated_at),0) "
         "from threads where updated_at >= %lld;", todayEpoch];
    NSArray<NSString *> *todayFields = SQLiteFields([[RunSQLite(path, todaySQL)
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@"\n"].firstObject);
    if (todayFields.count < 3) return UnavailableAIUsage(@"Codex", @"~/.codex/state_5.sqlite");

    NSString *weekSQL = [NSString stringWithFormat:
        @"select count(*), coalesce(sum(tokens_used),0), coalesce(max(updated_at),0) "
         "from threads where updated_at >= %lld;", weekEpoch];
    NSArray<NSString *> *weekFields = SQLiteFields([[RunSQLite(path, weekSQL)
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@"\n"].firstObject);

    long long modelStart = [todayFields[1] longLongValue] > 0 ? todayEpoch : weekEpoch;
    NSString *modelsSQL = [NSString stringWithFormat:
        @"select coalesce(nullif(model,''),'unknown'), count(*), coalesce(sum(tokens_used),0) "
         "from threads where updated_at >= %lld group by coalesce(nullif(model,''),'unknown') "
         "order by sum(tokens_used) desc limit 5;", modelStart];
    NSString *modelsOut = RunSQLite(path, modelsSQL);
    NSMutableArray *models = [NSMutableArray array];
    for (NSString *line in [modelsOut componentsSeparatedByString:@"\n"]) {
        NSArray<NSString *> *fields = SQLiteFields([line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
        if (fields.count < 3) continue;
        [models addObject:@{@"name": fields[0], @"sessions": @([fields[1] longLongValue]),
                            @"tokens": @([fields[2] longLongValue])}];
    }

    AIUsage *u = [AIUsage new];
    u.name = @"Codex";
    u.source = @"~/.codex/state_5.sqlite";
    u.available = YES;
    u.remainingFraction = -1;
    u.resetText = @"Not exposed locally";
    u.statusText = @"Local thread totals";
    u.statusReason = @"Codex's local thread store does not expose limit remaining or reset time";
    u.todaySessions = [todayFields[0] longLongValue];
    u.todayTokens = [todayFields[1] longLongValue];
    u.weekSessions = weekFields.count >= 1 ? [weekFields[0] longLongValue] : 0;
    u.weekTokens = weekFields.count >= 2 ? [weekFields[1] longLongValue] : 0;
    long long last = MAX([todayFields[2] longLongValue], weekFields.count >= 3 ? [weekFields[2] longLongValue] : 0);
    if (last > 0) u.lastActivity = [NSDate dateWithTimeIntervalSince1970:last];
    u.models = models;
    if (models.count) u.topModel = models.firstObject[@"name"];
    return u;
}

static NSArray<AIUsage *> *ReadAIUsage(void) {
    NSArray<AIUsage *> *usage = @[ReadClaudeUsage(), ReadCodexUsage()];
    NSString *statusPath = [NSHomeDirectory() stringByAppendingPathComponent:@".glancebar/ai-status.json"];
    NSDictionary *status = JSONDictionaryAtPath(statusPath);
    if (status) {
        for (AIUsage *u in usage) ApplyAIStatusFile(u, status, @"~/.glancebar/ai-status.json");
    }
    return usage;
}

#pragma mark - colors / small views

static NSColor *DiskColor(double frac) {
    return frac >= 0.95 ? NSColor.systemRedColor : frac >= 0.85 ? NSColor.systemOrangeColor : NSColor.controlAccentColor;
}
static NSColor *BattBarColor(int pct) {
    return pct <= 10 ? NSColor.systemRedColor : pct <= 20 ? NSColor.systemOrangeColor : NSColor.systemGreenColor;
}

@interface Gauge : NSView
@property double fraction; @property (strong) NSColor *color;
@end
@implementation Gauge
- (void)drawRect:(NSRect)d {
    NSRect r = self.bounds; CGFloat rad = r.size.height/2;
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad] fill];
    NSRect f = r; f.size.width = MAX(r.size.height, r.size.width*MIN(1.0,MAX(0,self.fraction)));
    [(self.color ?: NSColor.controlAccentColor) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:f xRadius:rad yRadius:rad] fill];
}
@end

@interface FlippedView : NSView @end
@implementation FlippedView - (BOOL)isFlipped { return YES; } @end

#pragma mark - bar image

static NSImage *TintedSymbol(NSString *name, double varValue, CGFloat pt, NSColor *color) {
    NSImage *img = varValue >= 0
        ? [NSImage imageWithSystemSymbolName:name variableValue:varValue accessibilityDescription:nil]
        : [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    img = [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pt
                                                                                           weight:NSFontWeightRegular]];
    if (!img) return nil;
    NSImage *out = [[NSImage alloc] initWithSize:img.size];
    [out lockFocus];
    [color set];
    NSRect r = (NSRect){.size = img.size};
    [img drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop);
    [out unlockFocus];
    out.template = NO;
    return out;
}

// Builds the menu-bar image from selected metric segments.
static NSImage *BarImage(NSArray<NSDictionary *> *segments, NSColor *fg) {
    CGFloat pt = 13, gap = 4, pad = 2;
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightRegular];
    if (!segments.count)
        segments = @[@{@"symbol": @"gauge.with.dots.needle.50percent", @"text": @"Glancebar"}];

    CGFloat h = 18;
    CGFloat w = pad;
    NSMutableArray<NSDictionary *> *draw = [NSMutableArray array];
    for (NSDictionary *seg in segments) {
        NSString *symbol = [seg[@"symbol"] isKindOfClass:NSString.class] ? seg[@"symbol"] : nil;
        NSNumber *var = [seg[@"var"] isKindOfClass:NSNumber.class] ? seg[@"var"] : nil;
        NSString *text = [seg[@"text"] isKindOfClass:NSString.class] ? seg[@"text"] : @"";
        NSImage *sym = symbol.length ? TintedSymbol(symbol, var ? var.doubleValue : -1, pt, fg) : nil;
        NSString *drawText = [NSString stringWithFormat:@" %@", text];
        NSSize textSize = [drawText sizeWithAttributes:@{NSFontAttributeName:font}];
        CGFloat segW = (sym ? sym.size.width : 0) + textSize.width;
        if (draw.count) w += gap*2;
        w += segW;
        [draw addObject:@{@"image": sym ?: [NSNull null], @"text": drawText,
                          @"textSize": [NSValue valueWithSize:textSize],
                          @"color": seg[@"color"] ?: fg}];
    }
    w += pad;

    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(ceil(w), h)];
    [img lockFocus];
    CGFloat x = pad;
    BOOL first = YES;
    for (NSDictionary *seg in draw) {
        if (!first) x += gap*2;
        first = NO;
        NSImage *sym = [seg[@"image"] isKindOfClass:NSImage.class] ? seg[@"image"] : nil;
        NSString *text = seg[@"text"];
        NSSize textSize = [seg[@"textSize"] sizeValue];
        if (sym) {
            [sym drawAtPoint:NSMakePoint(x, (h - sym.size.height)/2)
                    fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
            x += sym.size.width;
        }
        [text drawAtPoint:NSMakePoint(x, (h - textSize.height)/2)
           withAttributes:@{NSFontAttributeName:font,
                            NSForegroundColorAttributeName:(seg[@"color"] ?: fg)}];
        x += textSize.width;
    }
    [img unlockFocus];
    img.template = NO;  // we already used the adaptive fg color
    return img;
}

#pragma mark - Controller

static const CGFloat kW = 320, kPad = 16, kDetailW = 600, kDetailPad = 24;

@interface Controller : NSObject <NSApplicationDelegate>
@end

@interface Controller ()
- (void)rebuildContent;
- (void)rebuildDetails;
@end

@implementation Controller {
    NSStatusItem *_item;
    NSPopover *_popover;
    NSWindow *_detailsWindow;
    NSArray<Volume *> *_vols;
    BatteryState _bat;
    SystemState _sys;
    CPUCounters _cpuPrev;
    NSArray<AIUsage *> *_aiUsage;
    NSArray<NSDictionary *> *_hogs;
    NSArray<NSDictionary *> *_topCPU, *_topMem;
    NSMutableArray<NSNumber *> *_ampHistory;
    BOOL _showWatts, _showHealth, _hogsLoading, _hogsUnavailable;
    BOOL _barShowDisk, _barShowBattery, _barShowSystem, _barShowAI;
    BOOL _procStatsLoading, _procStatsUnavailable;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud registerDefaults:@{@"showWatts": @YES, @"showHealth": @YES,
                           @"barShowDisk": @YES, @"barShowBattery": @YES,
                           @"barShowSystem": @NO, @"barShowAI": @NO}];
    _showWatts = [ud boolForKey:@"showWatts"];
    _showHealth = [ud boolForKey:@"showHealth"];
    _barShowDisk = [ud boolForKey:@"barShowDisk"];
    _barShowBattery = [ud boolForKey:@"barShowBattery"];
    _barShowSystem = [ud boolForKey:@"barShowSystem"];
    _barShowAI = [ud boolForKey:@"barShowAI"];
    _ampHistory = [NSMutableArray array];
    _aiUsage = @[];
    _hogs = @[];
    _topCPU = @[];
    _topMem = @[];

    _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _item.button.target = self;
    _item.button.action = @selector(togglePopover:);

    _popover = [NSPopover new];
    _popover.behavior = NSPopoverBehaviorTransient;
    _popover.animates = YES;
    _popover.contentViewController = [NSViewController new];
    _popover.contentViewController.view = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,kW,10)];

    [self refresh];
    // Diagnostic: GLANCEBAR_AUTOOPEN=1 opens the popover on launch (for screenshots).
    if (getenv("GLANCEBAR_AUTOOPEN"))
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self togglePopover:nil]; });
    [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    CFRunLoopSourceRef src = IOPSNotificationCreateRunLoopSource(PSChanged, (__bridge void *)self);
    if (src) {
        CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopDefaultMode);
        CFRelease(src);
    }
}

static void PSChanged(void *ctx) { [(__bridge Controller *)ctx refresh]; }

- (void)refresh {
    _vols = ScanVolumes();
    _bat = ReadBattery();
    _sys = ReadSystemState(&_cpuPrev);
    _aiUsage = ReadAIUsage();
    if (_bat.valid) {
        [_ampHistory addObject:@(_bat.amperage_mA)];
        while (_ampHistory.count > 6) [_ampHistory removeObjectAtIndex:0];
    }
    [self updateBar];
    if (_popover.isShown) [self rebuildContent];
    if (_detailsWindow.isVisible) [self rebuildDetails];
}

- (double)avgAmp {
    if (!_ampHistory.count) return 0;
    double s = 0; for (NSNumber *a in _ampHistory) s += a.doubleValue;
    return s / _ampHistory.count;
}

- (int)rootDiskPct {
    for (Volume *v in _vols) if ([v.path isEqualToString:@"/"]) return (int)lround(v.fraction*100);
    return _vols.count ? (int)lround(_vols.firstObject.fraction*100) : 0;
}

- (AIUsage *)lowestAIStatus {
    AIUsage *lowest = nil;
    for (AIUsage *u in _aiUsage) {
        if (!u.limitStatusAvailable || u.remainingFraction < 0) continue;
        if (!lowest || u.remainingFraction < lowest.remainingFraction) lowest = u;
    }
    return lowest;
}

- (NSString *)aiPercentText:(AIUsage *)u {
    if (!u.limitStatusAvailable || u.remainingFraction < 0) return @"—";
    return [NSString stringWithFormat:@"%d%%", (int)lround(u.remainingFraction * 100)];
}

- (NSColor *)aiStatusColor:(AIUsage *)u {
    if (!u.limitStatusAvailable || u.remainingFraction < 0) return NSColor.tertiaryLabelColor;
    if (u.remainingFraction <= 0.15) return NSColor.systemRedColor;
    if (u.remainingFraction <= 0.35) return NSColor.systemOrangeColor;
    if (u.remainingFraction <= 0.60) return [NSColor.systemYellowColor colorWithAlphaComponent:0.9];
    return NSColor.systemGreenColor;
}

- (NSArray<NSDictionary *> *)barSegments {
    NSMutableArray *segments = [NSMutableArray array];
    NSColor *fg = NSColor.controlTextColor;
    if (_barShowDisk) {
        int pct = [self rootDiskPct];
        double frac = pct / 100.0;
        [segments addObject:@{@"symbol": @"internaldrive",
                              @"text": [NSString stringWithFormat:@"%d%%", pct],
                              @"color": frac >= 0.85 ? DiskColor(frac) : fg}];
    }
    if (_barShowBattery) {
        NSString *symbol = _bat.acConnected ? @"battery.100percent.bolt"
                         : _bat.percent <= 20 ? @"battery.25percent" : @"battery.100percent";
        NSString *text = _bat.valid ? [NSString stringWithFormat:@"%d%%", _bat.percent] : @"—";
        NSColor *color = _bat.valid && _bat.percent <= 20 && !_bat.acConnected ? BattBarColor(_bat.percent) : fg;
        NSMutableDictionary *seg = [@{@"symbol": symbol, @"text": text, @"color": color} mutableCopy];
        if (_bat.valid) seg[@"var"] = @(_bat.percent / 100.0);
        [segments addObject:seg];
    }
    if (_barShowSystem) {
        NSString *level = SystemPressureLevel(_sys);
        NSString *text = _sys.cpuValid ? [NSString stringWithFormat:@"%d%%", (int)lround(_sys.cpu * 100)] : @"SYS";
        [segments addObject:@{@"symbol": @"cpu", @"text": text, @"color": SystemPressureColor(level)}];
    }
    if (_barShowAI) {
        AIUsage *lowest = [self lowestAIStatus];
        NSString *text = lowest ? [NSString stringWithFormat:@"AI %@", [self aiPercentText:lowest]] : @"AI ?";
        [segments addObject:@{@"symbol": @"sparkles", @"text": text,
                              @"color": lowest ? [self aiStatusColor:lowest] : NSColor.secondaryLabelColor}];
    }
    return segments;
}

- (void)updateBar {
    _item.button.image = BarImage([self barSegments], NSColor.controlTextColor);
}

#pragma mark popover

- (void)togglePopover:(id)sender {
    if (_popover.isShown) { [_popover close]; return; }
    [self refresh];
    [self rebuildContent];
    [_popover showRelativeToRect:_item.button.bounds ofView:_item.button preferredEdge:NSMaxYEdge];
    [self sampleHogsAsync];
    [self sampleProcessStatsAsync];
}

- (void)sampleHogsAsync {
    _hogs = @[];
    _hogsLoading = YES;
    _hogsUnavailable = NO;
    if (_popover.isShown) [self rebuildContent];
    if (_detailsWindow.isVisible) [self rebuildDetails];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *hogs = SampleHogs(5);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_hogs = hogs ? hogs : @[];
            self->_hogsLoading = NO;
            self->_hogsUnavailable = self->_hogs.count == 0;
            if (self->_popover.isShown) [self rebuildContent];
            if (self->_detailsWindow.isVisible) [self rebuildDetails];
        });
    });
}

- (void)sampleProcessStatsAsync {
    _topCPU = @[];
    _topMem = @[];
    _procStatsLoading = YES;
    _procStatsUnavailable = NO;
    if (_popover.isShown) [self rebuildContent];
    if (_detailsWindow.isVisible) [self rebuildDetails];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *stats = SampleProcessStats(5);
        NSArray *cpu = stats[@"cpu"] ? stats[@"cpu"] : @[];
        NSArray *memory = stats[@"memory"] ? stats[@"memory"] : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_topCPU = cpu;
            self->_topMem = memory;
            self->_procStatsLoading = NO;
            self->_procStatsUnavailable = cpu.count == 0 && memory.count == 0;
            if (self->_popover.isShown) [self rebuildContent];
            if (self->_detailsWindow.isVisible) [self rebuildDetails];
        });
    });
}

// --- layout helpers ---
- (NSTextField *)text:(NSString *)s font:(NSFont *)f color:(NSColor *)c at:(NSRect)fr align:(NSTextAlignment)a {
    NSTextField *t = [NSTextField labelWithString:s ?: @""];
    t.font = f; if (c) t.textColor = c; t.alignment = a; t.frame = fr;
    t.lineBreakMode = NSLineBreakByTruncatingTail;
    return t;
}
- (NSView *)sectionHeader:(NSString *)title at:(CGFloat)y {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, 16)];
    [v addSubview:[self text:title.uppercaseString font:[NSFont systemFontOfSize:10 weight:NSFontWeightSemibold]
                       color:NSColor.tertiaryLabelColor at:NSMakeRect(kPad, 0, kW-2*kPad, 14) align:NSTextAlignmentLeft]];
    return v;
}
- (NSBox *)dividerAt:(CGFloat)y {
    NSBox *b = [[NSBox alloc] initWithFrame:NSMakeRect(kPad, y, kW-2*kPad, 1)];
    b.boxType = NSBoxSeparator; return b;
}
- (NSView *)processMetricRow:(NSDictionary *)h right:(NSString *)right fraction:(double)fraction color:(NSColor *)color
                       width:(CGFloat)width pad:(CGFloat)pad at:(CGFloat)y {
    NSDictionary *info = ProcessDisplayInfo(h);
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, width, 38)];
    CGFloat inner = width - 2*pad;
    CGFloat rightW = 92;
    [row addSubview:[self text:info[@"title"] font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold] color:nil
                          at:NSMakeRect(pad, 21, inner-rightW-6, 15) align:NSTextAlignmentLeft]];
    [row addSubview:[self text:right font:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]
                         color:NSColor.secondaryLabelColor at:NSMakeRect(width-pad-rightW, 21, rightW, 15) align:NSTextAlignmentRight]];
    [row addSubview:[self text:info[@"detail"] font:[NSFont systemFontOfSize:10.5] color:NSColor.secondaryLabelColor
                          at:NSMakeRect(pad, 6, inner, 13) align:NSTextAlignmentLeft]];
    Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(pad, 2, inner, 3.5)];
    g.fraction = fraction; g.color = color;
    [row addSubview:g];
    return row;
}
- (NSView *)processMetricRow:(NSDictionary *)h right:(NSString *)right fraction:(double)fraction color:(NSColor *)color at:(CGFloat)y {
    return [self processMetricRow:h right:right fraction:fraction color:color width:kW pad:kPad at:y];
}

- (NSView *)compactSignalRow:(NSString *)title right:(NSString *)right fraction:(double)fraction color:(NSColor *)color
                       width:(CGFloat)width pad:(CGFloat)pad at:(CGFloat)y {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, width, 28)];
    CGFloat inner = width - 2*pad;
    CGFloat rightW = 82;
    [row addSubview:[self text:title font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold] color:nil
                          at:NSMakeRect(pad, 11, inner-rightW-8, 15) align:NSTextAlignmentLeft]];
    [row addSubview:[self text:right font:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]
                         color:NSColor.secondaryLabelColor at:NSMakeRect(width-pad-rightW, 11, rightW, 15)
                         align:NSTextAlignmentRight]];
    Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(pad, 3, inner, 4)];
    g.fraction = MIN(1.0, MAX(0.0, fraction));
    g.color = color ?: NSColor.controlAccentColor;
    [row addSubview:g];
    return row;
}

- (NSString *)compactResetText:(AIUsage *)u {
    NSString *reset = u.resetText ?: @"Not exposed locally";
    if ([reset isEqualToString:@"Not exposed locally"]) return @"No local reset";
    return [NSString stringWithFormat:@"Reset: %@", reset];
}

- (NSString *)aiStatusSubtext:(AIUsage *)u {
    if (u.limitStatusAvailable) return [self compactResetText:u];
    if (!u.available) return @"No local state";
    return @"No limit status";
}

- (NSString *)aiResetDetailText:(AIUsage *)u {
    if (!u.limitStatusAvailable) return @"Not available";
    NSString *reset = u.resetText ?: @"";
    if (!reset.length || [reset isEqualToString:@"Not exposed locally"]) return @"Not provided";
    return reset;
}

- (NSView *)aiStatusRow:(AIUsage *)u width:(CGFloat)width pad:(CGFloat)pad at:(CGFloat)y {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, width, 44)];
    CGFloat inner = width - 2*pad;
    CGFloat rightW = 54;
    CGFloat titleW = 74;
    CGFloat barX = pad + titleW + 8;
    CGFloat barW = inner - titleW - rightW - 18;
    NSString *title = u.name ?: @"AI";
    [row addSubview:[self text:title font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold] color:nil
                          at:NSMakeRect(pad, 25, titleW, 15) align:NSTextAlignmentLeft]];
    [row addSubview:[self text:[self aiPercentText:u] font:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold]
                         color:[self aiStatusColor:u] at:NSMakeRect(width-pad-rightW, 23, rightW, 17) align:NSTextAlignmentRight]];
    Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(barX, 28, MAX(20, barW), 7)];
    g.fraction = u.limitStatusAvailable && u.remainingFraction >= 0 ? u.remainingFraction : 0;
    g.color = [self aiStatusColor:u];
    [row addSubview:g];
    [row addSubview:[self text:[self aiStatusSubtext:u] font:[NSFont systemFontOfSize:10.5] color:NSColor.secondaryLabelColor
                          at:NSMakeRect(pad, 7, inner, 14) align:NSTextAlignmentLeft]];
    return row;
}

- (NSString *)aiOverviewText {
    AIUsage *lowest = [self lowestAIStatus];
    if (lowest) return [NSString stringWithFormat:@"%@ %@ remaining · %@",
                        lowest.name, [self aiPercentText:lowest], [self aiStatusSubtext:lowest]];
    return @"Limit status unavailable";
}

- (void)rebuildContent {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,kW,2000)];
    CGFloat y = kPad;

    // ---------- STORAGE ----------
    [root addSubview:[self sectionHeader:@"Storage" at:y]]; y += 22;
    for (Volume *v in _vols) {
        NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, 50)];
        CGFloat inner = kW - 2*kPad;
        NSImage *ic = [NSImage imageWithSystemSymbolName:(v.isInternal ? @"internaldrive" : @"externaldrive")
                                accessibilityDescription:nil];
        NSImageView *iv = [NSImageView imageViewWithImage:ic];
        iv.contentTintColor = NSColor.secondaryLabelColor; iv.frame = NSMakeRect(kPad, 31, 17, 15);
        [row addSubview:iv];
        [row addSubview:[self text:v.name font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:nil
                              at:NSMakeRect(kPad+23, 31, inner-23-46, 16) align:NSTextAlignmentLeft]];
        [row addSubview:[self text:[NSString stringWithFormat:@"%d%%", (int)lround(v.fraction*100)]
                              font:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular]
                             color:NSColor.secondaryLabelColor at:NSMakeRect(kW-kPad-46, 31, 46, 16) align:NSTextAlignmentRight]];
        Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(kPad, 22, inner, 5)];
        g.fraction = v.fraction; g.color = DiskColor(v.fraction);
        [row addSubview:g];
        [row addSubview:[self text:[NSString stringWithFormat:@"%@ of %@ used · %@ free",
                                    FmtBytes(v.used), FmtBytes(v.total), FmtBytes(v.available)]
                              font:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor
                                at:NSMakeRect(kPad, 4, inner, 14) align:NSTextAlignmentLeft]];
        [root addSubview:row]; y += 54;
    }
    y += 2;
    [root addSubview:[self dividerAt:y]]; y += 13;

    // ---------- BATTERY ----------
    [root addSubview:[self sectionHeader:@"Battery" at:y]]; y += 22;
    if (_bat.valid) {
        NSString *big, *sub;
        if (_bat.acConnected) {
            if (_bat.fullyCharged || _bat.percent >= 100) { big = @"Fully charged"; sub = @"On AC power"; }
            else if (_bat.isCharging) { big = @"Charging"; sub = [NSString stringWithFormat:@"%d%% — plugged in", _bat.percent]; }
            else { big = [NSString stringWithFormat:@"Held at %d%%", _bat.percent]; sub = @"On AC, not charging"; }
        } else {
            big = [NSString stringWithFormat:@"%@ until 20%%", FmtDuration(MinutesTo20(_bat, [self avgAmp]))];
            sub = [NSString stringWithFormat:@"%d%% remaining", _bat.percent];
        }
        NSView *hl = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, 40)];
        [hl addSubview:[self text:big font:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold] color:nil
                             at:NSMakeRect(kPad, 18, kW-2*kPad, 20) align:NSTextAlignmentLeft]];
        [hl addSubview:[self text:sub font:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor
                             at:NSMakeRect(kPad, 3, kW-2*kPad, 14) align:NSTextAlignmentLeft]];
        [root addSubview:hl]; y += 44;
    }

    // battery pressure
    [root addSubview:[self text:@"Battery pressure" font:[NSFont systemFontOfSize:11]
                          color:NSColor.tertiaryLabelColor at:NSMakeRect(kPad, y, kW-2*kPad, 14) align:NSTextAlignmentLeft]];
    y += 18;
    if (_hogs.count == 0) {
        NSString *status = _hogsLoading ? @"measuring…" : (_hogsUnavailable ? @"Unavailable" : @"No active apps");
        [root addSubview:[self text:status font:[NSFont systemFontOfSize:12] color:NSColor.secondaryLabelColor
                               at:NSMakeRect(kPad, y, kW-2*kPad, 16) align:NSTextAlignmentLeft]]; y += 22;
    } else {
        double total = [_hogs.firstObject[@"totalImpact"] doubleValue];
        if (total <= 0) for (NSDictionary *h in _hogs) total += [h[@"impact"] doubleValue];
        NSDictionary *h = _hogs.firstObject;
        double share = total > 0 ? [h[@"impact"] doubleValue] / total : 0;
        NSDictionary *info = ProcessDisplayInfo(h);
        NSString *right = [NSString stringWithFormat:@"%d%%", (int)lround(share * 100)];
        [root addSubview:[self compactSignalRow:info[@"title"] right:right fraction:share color:PressureColor(share)
                                          width:kW pad:kPad at:y]];
        y += 30;
    }

    if (_bat.valid && ((_showWatts && _bat.voltage_mV > 0) || (_showHealth && _bat.designCap_mAh > 0))) {
        NSMutableArray<NSString *> *bits = [NSMutableArray array];
        if (_showWatts && _bat.voltage_mV > 0) {
            double watts = fabs((double)_bat.amperage_mA) * _bat.voltage_mV / 1e6;
            NSString *s = _bat.amperage_mA == 0 ? (_bat.acConnected ? @"On AC" : @"Drawing —")
                : [NSString stringWithFormat:@"%@ %.1f W", _bat.amperage_mA < 0 ? @"Drawing" : @"Charging", watts];
            [bits addObject:s];
        }
        if (_showHealth && _bat.designCap_mAh > 0) {
            [bits addObject:[NSString stringWithFormat:@"Health %d%%",
                             (int)lround(100.0*_bat.rawMax_mAh/_bat.designCap_mAh)]];
        }
        if (bits.count) {
            y += 2;
            [root addSubview:[self text:[bits componentsJoinedByString:@" · "] font:[NSFont systemFontOfSize:11]
                                  color:NSColor.secondaryLabelColor at:NSMakeRect(kPad, y, kW-2*kPad, 14)
                                  align:NSTextAlignmentLeft]];
            y += 18;
        }
    }

    // ---------- SYSTEM ----------
    y += 4;
    [root addSubview:[self dividerAt:y]]; y += 13;
    [root addSubview:[self sectionHeader:@"System" at:y]]; y += 22;
    NSString *sysLevel = SystemPressureLevel(_sys);
    NSView *sys = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, 50)];
    CGFloat inner = kW - 2*kPad;
    [sys addSubview:[self text:[NSString stringWithFormat:@"%@ system pressure", sysLevel]
                          font:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold]
                         color:SystemPressureColor(sysLevel)
                            at:NSMakeRect(kPad, 29, inner, 18) align:NSTextAlignmentLeft]];
    [sys addSubview:[self text:SystemSummaryText(_sys) font:[NSFont systemFontOfSize:11]
                         color:NSColor.secondaryLabelColor at:NSMakeRect(kPad, 13, inner, 14) align:NSTextAlignmentLeft]];
    Gauge *cpuGauge = [[Gauge alloc] initWithFrame:NSMakeRect(kPad, 5, inner, 4)];
    cpuGauge.fraction = _sys.cpuValid ? _sys.cpu : 0;
    cpuGauge.color = _sys.cpuValid ? CPUColor(_sys.cpu) : NSColor.tertiaryLabelColor;
    [sys addSubview:cpuGauge];
    [root addSubview:sys]; y += 54;

    if (_procStatsLoading) {
        [root addSubview:[self text:@"measuring top apps…" font:[NSFont systemFontOfSize:12]
                              color:NSColor.secondaryLabelColor at:NSMakeRect(kPad, y, inner, 16) align:NSTextAlignmentLeft]];
        y += 22;
    } else if (_procStatsUnavailable) {
        [root addSubview:[self text:@"Top apps unavailable" font:[NSFont systemFontOfSize:12]
                              color:NSColor.secondaryLabelColor at:NSMakeRect(kPad, y, inner, 16) align:NSTextAlignmentLeft]];
        y += 22;
    } else {
        if (_topCPU.count) {
            NSDictionary *h = _topCPU.firstObject;
            double cpu = [h[@"cpu"] doubleValue] / 100.0;
            NSDictionary *info = ProcessDisplayInfo(h);
            NSString *right = [NSString stringWithFormat:@"CPU %d%%", (int)lround([h[@"cpu"] doubleValue])];
            [root addSubview:[self compactSignalRow:info[@"title"] right:right fraction:(cpu < 1.0 ? cpu : 1.0)
                                              color:CPUColor(cpu) width:kW pad:kPad at:y]];
            y += 30;
        }
        if (_topMem.count) {
            uint64_t memTotal = _sys.memValid && _sys.memTotal > 0 ? _sys.memTotal : [_topMem.firstObject[@"bytes"] unsignedLongLongValue];
            NSDictionary *h = _topMem.firstObject;
            uint64_t bytes = [h[@"bytes"] unsignedLongLongValue];
            double frac = memTotal > 0 ? (double)bytes / (double)memTotal : 0;
            NSDictionary *info = ProcessDisplayInfo(h);
            [root addSubview:[self compactSignalRow:info[@"title"] right:FmtBytes(bytes)
                                           fraction:(frac < 1.0 ? frac : 1.0)
                                              color:SystemPressureColor(MemoryPressureLevel(_sys))
                                              width:kW pad:kPad at:y]];
            y += 30;
        }
    }

    // ---------- AI STATUS ----------
    y += 4;
    [root addSubview:[self dividerAt:y]]; y += 13;
    [root addSubview:[self sectionHeader:@"AI Status" at:y]]; y += 22;
    if (!_aiUsage.count) {
        [root addSubview:[self text:@"Limit status unavailable" font:[NSFont systemFontOfSize:12]
                              color:NSColor.secondaryLabelColor at:NSMakeRect(kPad, y, inner, 16) align:NSTextAlignmentLeft]];
        y += 22;
    } else {
        for (AIUsage *u in _aiUsage) {
            [root addSubview:[self aiStatusRow:u width:kW pad:kPad at:y]];
            y += 44;
        }
    }

    // ---------- footer ----------
    y += 4;
    [root addSubview:[self dividerAt:y]]; y += 9;
    NSView *foot = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, 24)];
    NSButton *opts = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:@"Options"]
                                        target:self action:@selector(showOptions:)];
    opts.bordered = NO; opts.frame = NSMakeRect(kPad-4, 0, 26, 22);
    [foot addSubview:opts];
    NSButton *details = [NSButton buttonWithTitle:@"Details…" target:self action:@selector(showDetails:)];
    details.bordered = NO; details.font = [NSFont systemFontOfSize:12];
    details.contentTintColor = NSColor.secondaryLabelColor;
    details.frame = NSMakeRect(kPad+28, 0, 76, 22);
    [foot addSubview:details];
    NSButton *quit = [NSButton buttonWithTitle:@"Quit" target:NSApp action:@selector(terminate:)];
    quit.bordered = NO; quit.font = [NSFont systemFontOfSize:12]; quit.contentTintColor = NSColor.secondaryLabelColor;
    quit.frame = NSMakeRect(kW-kPad-50, 0, 50, 22); quit.alignment = NSTextAlignmentRight;
    [foot addSubview:quit];
    [root addSubview:foot]; y += 26;

    y += kPad - 6;
    root.frame = NSMakeRect(0, 0, kW, y);
    CGFloat maxPopoverH = 720;
    if (y > maxPopoverH) {
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, kW, maxPopoverH)];
        scroll.borderType = NSNoBorder;
        scroll.drawsBackground = NO;
        scroll.hasVerticalScroller = YES;
        scroll.autohidesScrollers = YES;
        scroll.documentView = root;
        [scroll.contentView scrollToPoint:NSMakePoint(0, 0)];
        [scroll reflectScrolledClipView:scroll.contentView];
        _popover.contentSize = NSMakeSize(kW, maxPopoverH);
        _popover.contentViewController.view = scroll;
    } else {
        _popover.contentSize = NSMakeSize(kW, y);
        _popover.contentViewController.view = root;
    }
}

- (void)showOptions:(NSButton *)sender {
    NSMenu *m = [NSMenu new];
    NSMenuItem *barTitle = [m addItemWithTitle:@"Menu bar" action:nil keyEquivalent:@""];
    barTitle.enabled = NO;
    NSMenuItem *disk = [m addItemWithTitle:@"Show storage" action:@selector(toggleBarDisk:) keyEquivalent:@""];
    disk.target = self; disk.state = _barShowDisk ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *battery = [m addItemWithTitle:@"Show battery" action:@selector(toggleBarBattery:) keyEquivalent:@""];
    battery.target = self; battery.state = _barShowBattery ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *system = [m addItemWithTitle:@"Show system" action:@selector(toggleBarSystem:) keyEquivalent:@""];
    system.target = self; system.state = _barShowSystem ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *ai = [m addItemWithTitle:@"Show AI status" action:@selector(toggleBarAI:) keyEquivalent:@""];
    ai.target = self; ai.state = _barShowAI ? NSControlStateValueOn : NSControlStateValueOff;
    [m addItem:NSMenuItem.separatorItem];

    NSMenuItem *w = [m addItemWithTitle:@"Show current draw" action:@selector(toggleWatts:) keyEquivalent:@""];
    w.target = self; w.state = _showWatts ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *h = [m addItemWithTitle:@"Show battery health" action:@selector(toggleHealth:) keyEquivalent:@""];
    h.target = self; h.state = _showHealth ? NSControlStateValueOn : NSControlStateValueOff;
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height) inView:sender];
}
- (void)toggleWatts:(id)s { _showWatts = !_showWatts; [NSUserDefaults.standardUserDefaults setBool:_showWatts forKey:@"showWatts"]; [self rebuildContent]; }
- (void)toggleHealth:(id)s { _showHealth = !_showHealth; [NSUserDefaults.standardUserDefaults setBool:_showHealth forKey:@"showHealth"]; [self rebuildContent]; }

- (NSUInteger)enabledBarMetricCount {
    return (_barShowDisk ? 1 : 0) + (_barShowBattery ? 1 : 0) + (_barShowSystem ? 1 : 0) + (_barShowAI ? 1 : 0);
}

- (BOOL)canDisableBarMetric:(BOOL)current {
    return !current || [self enabledBarMetricCount] > 1;
}

- (void)saveBarOption:(NSString *)key value:(BOOL)value {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
    [self updateBar];
    if (_popover.isShown) [self rebuildContent];
}

- (void)toggleBarDisk:(id)s {
    if (![self canDisableBarMetric:_barShowDisk]) return;
    _barShowDisk = !_barShowDisk; [self saveBarOption:@"barShowDisk" value:_barShowDisk];
}
- (void)toggleBarBattery:(id)s {
    if (![self canDisableBarMetric:_barShowBattery]) return;
    _barShowBattery = !_barShowBattery; [self saveBarOption:@"barShowBattery" value:_barShowBattery];
}
- (void)toggleBarSystem:(id)s {
    if (![self canDisableBarMetric:_barShowSystem]) return;
    _barShowSystem = !_barShowSystem; [self saveBarOption:@"barShowSystem" value:_barShowSystem];
}
- (void)toggleBarAI:(id)s {
    if (![self canDisableBarMetric:_barShowAI]) return;
    _barShowAI = !_barShowAI; [self saveBarOption:@"barShowAI" value:_barShowAI];
}

- (Volume *)primaryVolume {
    for (Volume *v in _vols) if ([v.path isEqualToString:@"/"]) return v;
    return _vols.firstObject;
}

- (NSString *)batteryStatusText {
    if (!_bat.valid) return @"Unavailable";
    if (_bat.acConnected) {
        if (_bat.fullyCharged || _bat.percent >= 100) return @"Fully charged · on AC";
        if (_bat.isCharging) return [NSString stringWithFormat:@"%d%% · charging", _bat.percent];
        return [NSString stringWithFormat:@"%d%% · on AC, not charging", _bat.percent];
    }
    return [NSString stringWithFormat:@"%d%% · %@ until 20%%",
            _bat.percent, FmtDuration(MinutesTo20(_bat, [self avgAmp]))];
}

- (NSString *)batteryPowerText {
    if (!_bat.valid) return @"Unavailable";
    if (_bat.voltage_mV <= 0 || _bat.amperage_mA == 0) return _bat.acConnected ? @"On AC" : @"Estimating";
    double watts = fabs((double)_bat.amperage_mA) * _bat.voltage_mV / 1e6;
    return [NSString stringWithFormat:@"%@ %.1f W",
            _bat.amperage_mA < 0 ? @"Drawing" : @"Charging at", watts];
}

- (void)addDetailHeading:(NSString *)title to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width {
    if (*y > kDetailPad) *y += 8;
    [root addSubview:[self text:title.uppercaseString font:[NSFont systemFontOfSize:10 weight:NSFontWeightSemibold]
                         color:NSColor.tertiaryLabelColor at:NSMakeRect(kDetailPad, *y, width-2*kDetailPad, 14)
                         align:NSTextAlignmentLeft]];
    *y += 24;
}

- (void)addDetailKey:(NSString *)key value:(NSString *)value to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width {
    CGFloat keyW = 126;
    [root addSubview:[self text:key font:[NSFont systemFontOfSize:12] color:NSColor.secondaryLabelColor
                            at:NSMakeRect(kDetailPad, *y, keyW, 16) align:NSTextAlignmentLeft]];
    [root addSubview:[self text:value font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium] color:nil
                            at:NSMakeRect(kDetailPad+keyW, *y, width-2*kDetailPad-keyW, 16)
                         align:NSTextAlignmentLeft]];
    *y += 24;
}

- (void)addDetailStatus:(NSString *)status to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width {
    [root addSubview:[self text:status font:[NSFont systemFontOfSize:12] color:NSColor.secondaryLabelColor
                            at:NSMakeRect(kDetailPad, *y, width-2*kDetailPad, 16) align:NSTextAlignmentLeft]];
    *y += 24;
}

- (NSScrollView *)detailScrollForRoot:(NSView *)root height:(CGFloat)height {
    root.frame = NSMakeRect(0, 0, kDetailW, MAX(height + kDetailPad, 360));
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 420)];
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.documentView = root;
    return scroll;
}

- (NSTabViewItem *)detailTabWithIdentifier:(NSString *)identifier title:(NSString *)title view:(NSView *)view {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:identifier];
    item.label = title;
    item.view = view;
    return item;
}

- (NSScrollView *)overviewDetailsView {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 360)];
    CGFloat y = kDetailPad;
    [self addDetailHeading:@"Overview" to:root y:&y width:kDetailW];

    Volume *primary = [self primaryVolume];
    NSString *storage = primary
        ? [NSString stringWithFormat:@"%d%% used · %@ free on %@",
           (int)lround(primary.fraction * 100), FmtBytes(primary.available), primary.name]
        : @"Unavailable";
    [self addDetailKey:@"Storage" value:storage to:root y:&y width:kDetailW];
    [self addDetailKey:@"Battery" value:[self batteryStatusText] to:root y:&y width:kDetailW];
    [self addDetailKey:@"System" value:[NSString stringWithFormat:@"%@ · %@",
                                        SystemPressureLevel(_sys), SystemSummaryText(_sys)]
                    to:root y:&y width:kDetailW];
    [self addDetailKey:@"AI status" value:[self aiOverviewText] to:root y:&y width:kDetailW];

    [self addDetailHeading:@"Top Signals" to:root y:&y width:kDetailW];
    if (_hogsLoading || _procStatsLoading) {
        [self addDetailStatus:@"Measuring top apps…" to:root y:&y width:kDetailW];
    } else if (!_hogs.count && !_topCPU.count && !_topMem.count) {
        [self addDetailStatus:@"No sampled app activity" to:root y:&y width:kDetailW];
    } else {
        if (_hogs.count) {
            NSDictionary *h = _hogs.firstObject;
            double total = [_hogs.firstObject[@"totalImpact"] doubleValue];
            if (total <= 0) for (NSDictionary *row in _hogs) total += [row[@"impact"] doubleValue];
            double share = total > 0 ? [h[@"impact"] doubleValue] / total : 0;
            [root addSubview:[self processMetricRow:h right:[NSString stringWithFormat:@"Battery %d%%", (int)lround(share * 100)]
                                           fraction:share color:PressureColor(share) width:kDetailW pad:kDetailPad at:y]];
            y += 42;
        }
        if (_topCPU.count) {
            NSDictionary *h = _topCPU.firstObject;
            double cpu = [h[@"cpu"] doubleValue] / 100.0;
            [root addSubview:[self processMetricRow:h right:[NSString stringWithFormat:@"CPU %d%%", (int)lround([h[@"cpu"] doubleValue])]
                                           fraction:(cpu < 1.0 ? cpu : 1.0) color:CPUColor(cpu)
                                              width:kDetailW pad:kDetailPad at:y]];
            y += 42;
        }
        if (_topMem.count) {
            NSDictionary *h = _topMem.firstObject;
            uint64_t bytes = [h[@"bytes"] unsignedLongLongValue];
            uint64_t total = _sys.memValid && _sys.memTotal > 0 ? _sys.memTotal : bytes;
            double frac = total > 0 ? (double)bytes / (double)total : 0;
            [root addSubview:[self processMetricRow:h right:[NSString stringWithFormat:@"Mem %@", FmtBytes(bytes)]
                                           fraction:(frac < 1.0 ? frac : 1.0)
                                              color:SystemPressureColor(MemoryPressureLevel(_sys))
                                              width:kDetailW pad:kDetailPad at:y]];
            y += 42;
        }
    }
    return [self detailScrollForRoot:root height:y];
}

- (NSScrollView *)batteryDetailsView {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 520)];
    CGFloat y = kDetailPad;
    [self addDetailHeading:@"Battery" to:root y:&y width:kDetailW];
    if (!_bat.valid) {
        [self addDetailStatus:@"Battery unavailable" to:root y:&y width:kDetailW];
    } else {
        [self addDetailKey:@"Charge" value:[self batteryStatusText] to:root y:&y width:kDetailW];
        [self addDetailKey:@"Power" value:[self batteryPowerText] to:root y:&y width:kDetailW];
        if (!_bat.acConnected)
            [self addDetailKey:@"Until 20%" value:FmtDuration(MinutesTo20(_bat, [self avgAmp])) to:root y:&y width:kDetailW];
        if (_bat.designCap_mAh > 0) {
            NSString *health = [NSString stringWithFormat:@"%d%% · %ld/%ld mAh · %ld cycles",
                                (int)lround(100.0*_bat.rawMax_mAh/_bat.designCap_mAh),
                                _bat.rawMax_mAh, _bat.designCap_mAh, _bat.cycleCount];
            [self addDetailKey:@"Health" value:health to:root y:&y width:kDetailW];
        }
    }

    [self addDetailHeading:@"Battery Pressure" to:root y:&y width:kDetailW];
    if (_hogsLoading) {
        [self addDetailStatus:@"Measuring top apps…" to:root y:&y width:kDetailW];
    } else if (_hogsUnavailable || !_hogs.count) {
        [self addDetailStatus:@"No sampled battery pressure" to:root y:&y width:kDetailW];
    } else {
        double total = [_hogs.firstObject[@"totalImpact"] doubleValue];
        if (total <= 0) for (NSDictionary *h in _hogs) total += [h[@"impact"] doubleValue];
        for (NSDictionary *h in _hogs) {
            double share = total > 0 ? [h[@"impact"] doubleValue] / total : 0;
            NSString *right = [NSString stringWithFormat:@"%@  %d%%", PressureLevel(share), (int)lround(share * 100)];
            [root addSubview:[self processMetricRow:h right:right fraction:share color:PressureColor(share)
                                              width:kDetailW pad:kDetailPad at:y]];
            y += 42;
        }
    }
    return [self detailScrollForRoot:root height:y];
}

- (NSScrollView *)aiDetailsView {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 620)];
    CGFloat y = kDetailPad;
    [self addDetailHeading:@"AI Status" to:root y:&y width:kDetailW];

    for (AIUsage *u in _aiUsage) {
        [self addDetailHeading:u.name ?: @"AI" to:root y:&y width:kDetailW];
        [self addDetailKey:@"Remaining" value:[self aiPercentText:u] to:root y:&y width:kDetailW];
        [self addDetailKey:@"Reset" value:[self aiResetDetailText:u] to:root y:&y width:kDetailW];
        [self addDetailKey:@"Status" value:u.limitStatusAvailable ? (u.statusReason ?: @"Limit status available")
                                                                   : (u.statusReason ?: @"No limit status source")
                        to:root y:&y width:kDetailW];
        if (u.statusSource)
            [self addDetailKey:@"Status source" value:u.statusSource to:root y:&y width:kDetailW];
    }

    [self addDetailHeading:@"Local History" to:root y:&y width:kDetailW];
    for (AIUsage *u in _aiUsage) {
        [self addDetailHeading:u.name ?: @"AI" to:root y:&y width:kDetailW];
        if (!u.available) {
            [self addDetailStatus:u.statusText ?: @"Local state not found" to:root y:&y width:kDetailW];
            [self addDetailKey:@"Source" value:u.source ?: @"unknown" to:root y:&y width:kDetailW];
            continue;
        }
        [self addDetailKey:@"Today" value:u.todayTokens > 0 ? FmtTokenCount(u.todayTokens) : @"No local usage today"
                        to:root y:&y width:kDetailW];
        [self addDetailKey:@"7 days" value:u.weekTokens > 0 ? FmtTokenCount(u.weekTokens) : @"No local usage"
                        to:root y:&y width:kDetailW];
        if (u.todaySessions > 0 || u.weekSessions > 0) {
            NSString *sessions = [NSString stringWithFormat:@"%lld today · %lld in 7d", u.todaySessions, u.weekSessions];
            [self addDetailKey:@"Sessions" value:sessions to:root y:&y width:kDetailW];
        }
        if (u.todayMessages > 0) {
            NSString *activity = [NSString stringWithFormat:@"%lld messages · %lld tool calls",
                                  u.todayMessages, u.todayToolCalls];
            [self addDetailKey:@"Activity" value:activity to:root y:&y width:kDetailW];
        }
        [self addDetailKey:@"Status" value:u.statusText ?: @"Local stats" to:root y:&y width:kDetailW];
        if (u.lastActivity)
            [self addDetailKey:@"Updated" value:ClockText(u.lastActivity) to:root y:&y width:kDetailW];
        [self addDetailKey:@"Source" value:u.source ?: @"unknown" to:root y:&y width:kDetailW];

        if (u.models.count) {
            [self addDetailHeading:@"Models" to:root y:&y width:kDetailW];
            for (NSDictionary *model in u.models) {
                NSString *name = ShortModelName(model[@"name"]);
                NSNumber *tokens = [model[@"tokens"] isKindOfClass:NSNumber.class] ? model[@"tokens"] : @0;
                NSNumber *sessions = [model[@"sessions"] isKindOfClass:NSNumber.class] ? model[@"sessions"] : nil;
                NSString *right = sessions ? [NSString stringWithFormat:@"%@ · %@ sessions", FmtTokenCount(tokens.longLongValue), sessions]
                                           : FmtTokenCount(tokens.longLongValue);
                [self addDetailKey:name value:right to:root y:&y width:kDetailW];
            }
        }
    }
    return [self detailScrollForRoot:root height:y];
}

- (NSScrollView *)systemDetailsView {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 620)];
    CGFloat y = kDetailPad;
    [self addDetailHeading:@"System" to:root y:&y width:kDetailW];
    [self addDetailKey:@"Pressure" value:SystemPressureLevel(_sys) to:root y:&y width:kDetailW];
    [self addDetailKey:@"CPU" value:CPUStatusText(_sys) to:root y:&y width:kDetailW];
    [self addDetailKey:@"Memory" value:MemoryStatusText(_sys) to:root y:&y width:kDetailW];
    [self addDetailKey:@"Swap" value:SwapStatusText(_sys) to:root y:&y width:kDetailW];

    [self addDetailHeading:@"Top CPU" to:root y:&y width:kDetailW];
    if (_procStatsLoading) {
        [self addDetailStatus:@"Measuring top apps…" to:root y:&y width:kDetailW];
    } else if (!_topCPU.count) {
        [self addDetailStatus:@"No sampled CPU activity" to:root y:&y width:kDetailW];
    } else {
        for (NSDictionary *h in _topCPU) {
            double cpu = [h[@"cpu"] doubleValue] / 100.0;
            NSString *right = [NSString stringWithFormat:@"%d%%", (int)lround([h[@"cpu"] doubleValue])];
            [root addSubview:[self processMetricRow:h right:right fraction:(cpu < 1.0 ? cpu : 1.0)
                                              color:CPUColor(cpu) width:kDetailW pad:kDetailPad at:y]];
            y += 42;
        }
    }

    [self addDetailHeading:@"Top Memory" to:root y:&y width:kDetailW];
    if (_procStatsLoading) {
        [self addDetailStatus:@"Measuring top apps…" to:root y:&y width:kDetailW];
    } else if (!_topMem.count) {
        [self addDetailStatus:@"No sampled memory activity" to:root y:&y width:kDetailW];
    } else {
        uint64_t memTotal = _sys.memValid && _sys.memTotal > 0 ? _sys.memTotal : [_topMem.firstObject[@"bytes"] unsignedLongLongValue];
        for (NSDictionary *h in _topMem) {
            uint64_t bytes = [h[@"bytes"] unsignedLongLongValue];
            double frac = memTotal > 0 ? (double)bytes / (double)memTotal : 0;
            [root addSubview:[self processMetricRow:h right:FmtBytes(bytes) fraction:(frac < 1.0 ? frac : 1.0)
                                              color:SystemPressureColor(MemoryPressureLevel(_sys))
                                              width:kDetailW pad:kDetailPad at:y]];
            y += 42;
        }
    }
    return [self detailScrollForRoot:root height:y];
}

- (void)rebuildDetails {
    if (!_detailsWindow) return;

    id selected = nil;
    for (NSView *subview in _detailsWindow.contentView.subviews) {
        if ([subview isKindOfClass:NSTabView.class]) {
            selected = ((NSTabView *)subview).selectedTabViewItem.identifier;
            break;
        }
    }

    NSRect bounds = _detailsWindow.contentView ? _detailsWindow.contentView.bounds : NSMakeRect(0, 0, 640, 520);
    if (bounds.size.width < 100 || bounds.size.height < 100) bounds = NSMakeRect(0, 0, 640, 520);
    NSView *content = [[NSView alloc] initWithFrame:bounds];
    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSInsetRect(content.bounds, 12, 12)];
    tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [tabs addTabViewItem:[self detailTabWithIdentifier:@"overview" title:@"Overview" view:[self overviewDetailsView]]];
    [tabs addTabViewItem:[self detailTabWithIdentifier:@"battery" title:@"Battery" view:[self batteryDetailsView]]];
    [tabs addTabViewItem:[self detailTabWithIdentifier:@"system" title:@"System" view:[self systemDetailsView]]];
    [tabs addTabViewItem:[self detailTabWithIdentifier:@"ai" title:@"AI" view:[self aiDetailsView]]];
    [content addSubview:tabs];
    _detailsWindow.contentView = content;

    NSTabViewItem *selectedItem = nil;
    for (NSTabViewItem *item in tabs.tabViewItems) {
        if (selected && [item.identifier isEqual:selected]) { selectedItem = item; break; }
    }
    [tabs selectTabViewItem:(selectedItem ?: tabs.tabViewItems.firstObject)];
}

- (void)showDetails:(id)sender {
    [self refresh];
    BOOL didCreateWindow = (_detailsWindow == nil);
    if (!_detailsWindow) {
        _detailsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 520)
                                                     styleMask:(NSWindowStyleMaskTitled |
                                                                NSWindowStyleMaskClosable |
                                                                NSWindowStyleMaskMiniaturizable |
                                                                NSWindowStyleMaskResizable)
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
        _detailsWindow.title = @"Glancebar Details";
        _detailsWindow.releasedWhenClosed = NO;
        _detailsWindow.minSize = NSMakeSize(540, 420);
    }
    [self rebuildDetails];
    if (didCreateWindow) [_detailsWindow center];
    [_detailsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [_popover close];
    [self sampleHogsAsync];
    [self sampleProcessStatsAsync];
}

@end

#pragma mark - main

static void Dump(void) {
    for (Volume *v in ScanVolumes())
        printf("disk  %-16s %3d%%  %s free\n",
               v.name.UTF8String, (int)lround(v.fraction*100), FmtBytes(v.available).UTF8String);
    BatteryState b = ReadBattery();
    if (b.valid) {
        printf("batt  %d%% (%s)\n", b.percent, b.acConnected ? "on AC" : "on battery");
        if (!b.acConnected) printf("      %s until 20%%\n", FmtDuration(MinutesTo20(b, b.amperage_mA)).UTF8String);
        if (b.designCap_mAh > 0)
            printf("      health %d%% · %ld cycles\n", (int)lround(100.0*b.rawMax_mAh/b.designCap_mAh), b.cycleCount);
    }
    printf("battery pressure:\n");
    NSArray *hogs = SampleHogs(5);
    if (!hogs.count) printf("  unavailable\n");
    double total = [hogs.firstObject[@"totalImpact"] doubleValue];
    if (total <= 0) for (NSDictionary *h in hogs) total += [h[@"impact"] doubleValue];
    for (NSDictionary *h in hogs) {
        double share = total > 0 ? [h[@"impact"] doubleValue] / total : 0;
        NSDictionary *info = ProcessDisplayInfo(h);
        printf("  %3d%%  %-18s %s\n", (int)lround(share * 100),
               [info[@"title"] UTF8String], [info[@"detail"] UTF8String]);
    }

    CPUCounters prev = ReadCPUCounters();
    [NSThread sleepForTimeInterval:0.25];
    SystemState sys = ReadSystemState(&prev);
    printf("system %s\n", [SystemSummaryText(sys) UTF8String]);
    NSDictionary *stats = SampleProcessStats(3);
    NSArray *cpu = stats[@"cpu"] ? stats[@"cpu"] : @[];
    NSArray *memory = stats[@"memory"] ? stats[@"memory"] : @[];
    if (!cpu.count && !memory.count) printf("top apps unavailable\n");
    if (cpu.count) {
        printf("top cpu:\n");
        for (NSDictionary *h in cpu) {
            NSDictionary *info = ProcessDisplayInfo(h);
            printf("  %3.0f%%  %-18s %s\n", [h[@"cpu"] doubleValue],
                   [info[@"title"] UTF8String], [info[@"detail"] UTF8String]);
        }
    }
    if (memory.count) {
        printf("top memory:\n");
        for (NSDictionary *h in memory) {
            NSDictionary *info = ProcessDisplayInfo(h);
            printf("  %6s  %-18s %s\n", [FmtBytes([h[@"bytes"] unsignedLongLongValue]) UTF8String],
                   [info[@"title"] UTF8String], [info[@"detail"] UTF8String]);
        }
    }

    printf("ai status:\n");
    for (AIUsage *u in ReadAIUsage()) {
        NSString *remaining = u.limitStatusAvailable ? [NSString stringWithFormat:@"%d%% remaining",
                                                         (int)lround(u.remainingFraction * 100)]
                                                      : @"remaining unavailable";
        NSString *reset = @"reset unavailable";
        if (u.limitStatusAvailable) {
            reset = (u.resetText.length && ![u.resetText isEqualToString:@"Not exposed locally"]) ? u.resetText : @"reset not provided";
        }
        printf("  %-7s %s · %s\n",
               u.name.UTF8String,
               remaining.UTF8String,
               reset.UTF8String);
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--dump") == 0) { Dump(); return 0; }
        NSApplication *app = NSApplication.sharedApplication;
        Controller *c = [Controller new];
        app.delegate = c;
        [app run];
    }
    return 0;
}
