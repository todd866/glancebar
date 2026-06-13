// Glancebar — one configurable menu bar item at a glance. Click for a native popover
// with storage, battery, system, and AI summaries plus a deeper details window.
// Single-file Objective-C/AppKit. Zero dependencies, no sudo. Pure logic in pure.{h,m}.
#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <Security/Security.h>
#import <libproc.h>
#import <mach/mach.h>
#import <sys/mount.h>
#import <sys/sysctl.h>
#import <os/log.h>
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

// Physical footprint (what Activity Monitor shows) — unlike RSS it does not count
// shared framework pages once per helper process.
static unsigned long long FootprintForPid(pid_t pid) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) == 0)
        return ri.ri_phys_footprint;
    return 0;
}

static NSDictionary<NSString *, NSArray<NSDictionary *> *> *SampleProcessStats(int topN) {
    NSString *out = RunTaskOutput(@"/bin/ps", @[@"-axo", @"pid=,pcpu=,rss=,comm="]);
    return ParseProcessStats(out ? out : @"", topN,
                             ^NSString *(pid_t pid){ return AppGroupForPid(pid); },
                             ^unsigned long long (pid_t pid){ return FootprintForPid(pid); });
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
    int kernPressure;   // kern.memorystatus_vm_pressure_level: 1/2/4, 0 = unknown
} SystemState;

// mach_host_self() returns a send right each call and the urefs are never returned;
// fetch it once.
static host_t HostPort(void) {
    static host_t port;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ port = mach_host_self(); });
    return port;
}

static int CoreCount(void) {
    static int cores;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int v = 0; size_t sz = sizeof(v);
        if (sysctlbyname("hw.logicalcpu", &v, &sz, NULL, 0) != 0 || v < 1) v = 1;
        cores = v;
    });
    return cores;
}

// ps reports %cpu per core (a busy group can exceed 100%); normalize to the same
// all-cores scale as the headline CPU% so the two are comparable.
static double GroupCPUShare(NSDictionary *h) {
    return [h[@"cpu"] doubleValue] / 100.0 / CoreCount();
}

static CPUCounters ReadCPUCounters(void) {
    CPUCounters c = {0};
    natural_t cpuCount = 0;
    processor_info_array_t cpuInfo = NULL;
    mach_msg_type_number_t cpuInfoCount = 0;
    kern_return_t kr = host_processor_info(HostPort(), PROCESSOR_CPU_LOAD_INFO,
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
    // Per-CPU tick counters are 32-bit and can wrap on long uptimes; a wrapped delta
    // would underflow to ~2^64. Discard the sample instead.
    if (now.valid && previous && previous->valid &&
        now.user >= previous->user && now.system >= previous->system &&
        now.nice >= previous->nice && now.idle >= previous->idle) {
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
        if (host_page_size(HostPort(), &pageSize) == KERN_SUCCESS &&
            host_statistics64(HostPort(), HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS) {
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

    int pressure = 0;
    size_t pressureSize = sizeof(pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, NULL, 0) == 0)
        s.kernPressure = pressure;

    return s;
}

static NSString *MemoryPressureLevel(SystemState s) {
    // Prefer the kernel memorystatus subsystem's own verdict: Apple Silicon swaps
    // aggressively while perfectly healthy, so fixed swap thresholds cry wolf.
    if (s.kernPressure == 4) return @"High";
    if (s.kernPressure == 2) return @"Medium";
    if (s.kernPressure == 1) return @"Low";
    // Fallback heuristic when the sysctl is unavailable:
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
    if (s.swapUsed == 0) return @"Swap none";   // NSByteCountFormatter renders 0 as "Zero KB"
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
@property (copy) NSString *extraUsage;   // e.g. "9,122 of 10,000 AUD (91%)"
@property (copy) NSString *diagnostics;   // --dump only: why the gauge is or isn't shown
@property BOOL available, stale, limitStatusAvailable, overageActive;
@property double remainingFraction;
@property long long todayTokens, weekTokens, todayMessages, todaySessions, todayToolCalls, weekSessions;
@property long long todayTokensAll, weekTokensAll;   // incl. cached context re-reads
@property (strong) NSDate *lastActivity;
@property (copy) NSArray<NSDictionary *> *models;
@end
@implementation AIUsage @end

// Unified logging for the AI pipeline: transitions only, metadata only (booleans,
// HTTP codes, our own status strings — never tokens, counts, or credentials).
// View: log show --predicate 'subsystem == "com.iantodd.glancebar"' --last 12h
static os_log_t GBAILog(void) {
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.iantodd.glancebar", "ai"); });
    return log;
}
#define GBLog(fmt, ...) os_log(GBAILog(), fmt, ##__VA_ARGS__)

static NSString *FmtEpochClock(double epoch) {   // "12:12:08", or "—" when unset
    if (epoch <= 0) return @"—";
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"HH:mm:ss";
    return [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:epoch]];
}
static NSString *FmtEpochDayClock(double epoch) {   // "12/6 04:08", or "—" when unset
    if (epoch <= 0) return @"—";
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"d/M HH:mm";
    return [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:epoch]];
}

static NSString *FmtCompact(long long n) {
    double v = (double)llabs(n);
    NSString *sign = n < 0 ? @"-" : @"";
    // Tier thresholds sit at the rounding boundary so 999.6M prints 1.0B, not 1000.0M.
    if (v >= 999500000.0) return [NSString stringWithFormat:@"%@%.1fB", sign, v / 1000000000.0];
    if (v >= 999500.0) return [NSString stringWithFormat:@"%@%.1fM", sign, v / 1000000.0];
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

// Bare formatted time — callers add their own "Reset"/"Reset:" framing.
static NSString *ResetTextFromDate(NSDate *date) {
    if (!date) return nil;
    NSDateFormatter *fmt = [NSDateFormatter new];
    BOOL today = [NSCalendar.currentCalendar isDate:date inSameDayAsDate:NSDate.date];
    fmt.dateStyle = today ? NSDateFormatterNoStyle : NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    return [fmt stringFromDate:date];
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
    if (!date) {
        iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        date = [iso dateFromString:s];
    }
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

    // Interpret by key, not magnitude: a "guess the unit" heuristic misreads 0.9%
    // remaining as 90% — exactly when the number matters most.
    NSNumber *fraction = StatusNumberForKeys(entry, @[@"remainingFraction", @"fractionRemaining"]);
    NSNumber *percent = StatusNumberForKeys(entry, @[@"remainingPercent", @"percentRemaining", @"percentageRemaining"]);
    double v = fraction ? fraction.doubleValue : (percent ? percent.doubleValue / 100.0 : -1);
    if (v >= 0) {
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
    u.statusReason = @"Claude account access is off";

    NSDate *now = NSDate.date;
    NSDate *todayStart = StartOfLocalDay(now);
    // Calendar arithmetic, not 6*86400: a DST transition makes the fixed-seconds week
    // window silently drop its oldest day.
    NSDate *weekStart = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay
                                                               value:-6 toDate:todayStart options:0] ?: todayStart;
    NSString *today = LocalDateString(now);
    NSString *lastComputed = [root[@"lastComputedDate"] isKindOfClass:NSString.class] ? root[@"lastComputedDate"] : nil;
    u.stale = lastComputed.length && ![lastComputed isEqualToString:today];
    u.statusText = !lastComputed.length ? @"Local stats (freshness unknown)"
                 : u.stale ? [NSString stringWithFormat:@"Stats through %@", ShortDateText(lastComputed)]
                 : @"Local stats current";

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

// Opt-in only (the "Claude account for limit status" toggle): Claude Code keeps no
// quota state on disk — its /usage panel fetches from the API — so the only true gauge
// source is the same OAuth endpoint, authenticated with the token Claude Code already
// maintains in the Keychain. Returns nil when the toggle is off conceptually (callers
// gate), the item is missing, or access is denied.
// Expiry is judged by the caller via ClaudeKeychainOutcome (never refresh the token
// ourselves — that could rotate the refresh token out from under Claude Code).
static NSDictionary *ClaudeAccessTokenFromKeychain(void) {
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService: @"Claude Code-credentials",
                            (__bridge id)kSecReturnData: @YES,
                            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne};
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) return nil;
    NSData *data = CFBridgingRelease(result);
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *oauth = [json[@"claudeAiOauth"] isKindOfClass:NSDictionary.class] ? json[@"claudeAiOauth"] : nil;
    if (!oauth) return nil;
    NSString *token = [oauth[@"accessToken"] isKindOfClass:NSString.class] ? oauth[@"accessToken"] : nil;
    double expiresAt = [oauth[@"expiresAt"] doubleValue] / 1000.0;   // ms epoch
    return @{@"token": token ?: @"", @"expiresAt": @(expiresAt)};    // expiry judged by the caller
}

// One GET to Anthropic's OAuth usage endpoint — the same data Claude Code's /usage
// shows. Synchronous by design: callers run on the AI queue, never the main thread.
static NSDictionary *FetchClaudeUsageJSON(NSString *token) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.anthropic.com/api/oauth/usage"]];
    req.timeoutInterval = 10;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"oauth-2025-04-20" forHTTPHeaderField:@"anthropic-beta"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.URLCache = nil;
    cfg.HTTPCookieStorage = nil;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.HTTPShouldSetCookies = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *json = nil;
    __block BOOL completed = NO;
    __block NSInteger statusCode = 0;
    __block NSTimeInterval retryAfter = 0;
    __block NSString *errorMessage = nil;
    [[session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
            statusCode = http.statusCode;
            retryAfter = [http.allHeaderFields[@"Retry-After"] doubleValue];
            if (!err && http.statusCode == 200 && data.length) {
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([obj isKindOfClass:NSDictionary.class]) json = obj;
            } else {
                if (data.length) {
                    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    NSDictionary *dict = [obj isKindOfClass:NSDictionary.class] ? obj : nil;
                    NSDictionary *error = [dict[@"error"] isKindOfClass:NSDictionary.class] ? dict[@"error"] : nil;
                    NSString *message = [error[@"message"] isKindOfClass:NSString.class] ? error[@"message"] : nil;
                    if (message.length) errorMessage = message;
                }
                if (!errorMessage.length && err.localizedDescription.length) errorMessage = err.localizedDescription;
            }
            completed = YES;
            [session finishTasksAndInvalidate];
            dispatch_semaphore_signal(done);
        }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    if (!completed) [session invalidateAndCancel];
    if (!json) {
        NSString *message = errorMessage.length ? errorMessage
            : statusCode > 0 ? [NSHTTPURLResponse localizedStringForStatusCode:statusCode]
            : @"Claude usage API request timed out";
        return @{@"_glancebarFetchError": @YES,
                 @"statusCode": @(statusCode),
                 @"rateLimited": @(statusCode == 429),
                 @"retryAfter": @(retryAfter),
                 @"message": message};
    }
    return json;
}

// Codex's sqlite schema versions its filename (state_5.sqlite today); pick the
// highest-versioned one so a Codex update doesn't silently blank the panel.
static NSString *CodexStatePath(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@".codex"];
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    NSString *best = nil;
    long bestVersion = -1;
    for (NSString *name in names) {
        if (![name hasPrefix:@"state_"] || ![name hasSuffix:@".sqlite"] || name.length <= 13) continue;
        long v = [name substringWithRange:NSMakeRange(6, name.length - 13)].integerValue;
        if (v > bestVersion) { bestVersion = v; best = name; }
    }
    return best ? [dir stringByAppendingPathComponent:best] : nil;
}

static NSDate *FileMTime(NSString *path) {
    return [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
}

// Reads AI usage state. Codex tokens come from the per-turn token_count events in the
// session rollout JSONLs — the only accurate per-day source (the sqlite tokens_used
// column is a lifetime counter, so windowing it attributes a resumed thread's whole
// history to "today"). Rollouts are append-only; per-file byte offsets make the steady
// state a handful of stats per tick. Stateful and not reentrant: call from one serial
// queue only (the --dump path makes its own throwaway instance).
@interface AIReader : NSObject
@property BOOL useClaudeAccount;
@property BOOL allowClaudeAccountFetch;
@property BOOL allowClaudeTranscripts;
- (NSArray<AIUsage *> *)read;
@end

@implementation AIReader {
    NSMutableDictionary<NSString *, NSNumber *> *_offsets;   // rollout basename -> consumed bytes
    NSMutableDictionary<NSString *, NSDictionary *> *_days;  // local "yyyy-MM-dd" -> @{@"t":, @"f":}
    NSDictionary *_limits;          // newest rate_limits seen
    NSString *_limitsTs;
    NSDate *_dbStamp;               // change detection for the sqlite extras
    NSString *_dbDay;
    long long _sessionsToday;
    NSArray<NSDictionary *> *_models;
    NSDate *_lastActivity;
    NSMutableDictionary<NSString *, NSNumber *> *_claudeOffsets;  // transcript rel path -> consumed bytes
    NSMutableDictionary<NSString *, NSDictionary *> *_claudeDays;
    NSMutableSet<NSString *> *_claudeSeenIds;   // duplicate transcript lines share a message id
    NSDictionary *_claudeUsageJSON;             // last good OAuth usage response
    double _claudeNextFetch;                    // epoch; throttles the usage endpoint
    NSString *_claudeAccessToken;               // memory-only; never persisted by Glancebar
    double _claudeAccessTokenExpiresAt;
    double _claudeKeychainNextTry;
    NSString *_claudeAccountStatus;
    NSString *_lastFetchSkipReason;
    NSMutableDictionary<NSString *, NSString *> *_lastStatusReasons;
}

- (instancetype)init {
    if ((self = [super init])) {
        _offsets = [NSMutableDictionary dictionary];
        _days = [NSMutableDictionary dictionary];
        _claudeOffsets = [NSMutableDictionary dictionary];
        _claudeDays = [NSMutableDictionary dictionary];
        _claudeSeenIds = [NSMutableSet set];
        _lastStatusReasons = [NSMutableDictionary dictionary];
    }
    return self;
}

// Reads the complete lines appended to an append-only file since the recorded offset
// and advances it; a partially-written trailing line is re-read next pass.
- (NSData *)newLineDataAtPath:(NSString *)path key:(NSString *)key
                      offsets:(NSMutableDictionary<NSString *, NSNumber *> *)offsets {
    static const NSUInteger kMaxLogReadBytes = 1024 * 1024;
    unsigned long long offset = [offsets[key] unsignedLongLongValue];
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;
    unsigned long long size = [fh seekToEndOfFile];
    if (offset > size) offset = 0;   // file was truncated/recreated
    [fh seekToFileOffset:offset];
    NSData *data = [fh readDataOfLength:kMaxLogReadBytes];
    [fh closeFile];
    if (!data.length) return nil;
    const char *bytes = data.bytes;
    NSUInteger consume = 0;
    for (NSUInteger i = data.length; i > 0; i--) {
        if (bytes[i - 1] == '\n') { consume = i; break; }
    }
    if (!consume && data.length >= kMaxLogReadBytes) {
        offsets[key] = @(offset + data.length);   // drop a pathological overlong line
        return nil;
    }
    if (!consume) return nil;
    offsets[key] = @(offset + consume);
    return [data subdataWithRange:NSMakeRange(0, consume)];
}

// Byte-level line iteration: transcripts run to gigabytes, so only lines containing
// `needle` are ever converted to NSString (the conversion dominates a naive scan).
static void ForEachMatchingLine(NSData *data, const char *needle, void (^block)(NSString *line)) {
    const char *bytes = data.bytes;
    size_t len = data.length, needleLen = strlen(needle), start = 0;
    while (start < len) {
        const char *nl = memchr(bytes + start, '\n', len - start);
        size_t lineLen = nl ? (size_t)(nl - (bytes + start)) : len - start;
        if (lineLen >= needleLen && memmem(bytes + start, lineLen, needle, needleLen)) {
            NSString *line = [[NSString alloc] initWithBytes:bytes + start length:lineLen
                                                    encoding:NSUTF8StringEncoding];
            if (line) block(line);
        }
        if (!nl) break;
        start += lineLen + 1;
    }
}

static NSString *WeekStartDayString(void) {
    NSDate *weekStart = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-6
                                                              toDate:StartOfLocalDay(NSDate.date) options:0];
    return LocalDateString(weekStart);
}

static void PruneDays(NSMutableDictionary *days, NSString *weekStartDay) {
    for (NSString *day in days.allKeys)
        if ([day compare:weekStartDay] == NSOrderedAscending) [days removeObjectForKey:day];
}

// Rollout files keep their unique basename when they move from sessions/ to
// archived_sessions/, so offsets keyed by basename survive archiving without
// double-counting.
- (void)scanRollouts {
    NSString *home = NSHomeDirectory();
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-8 * 24 * 3600];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *dir in @[@".codex/sessions", @".codex/archived_sessions"]) {
        NSString *base = [home stringByAppendingPathComponent:dir];
        NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtPath:base];
        for (NSString *rel in en) {
            if (![rel.pathExtension isEqualToString:@"jsonl"]) continue;
            NSDictionary *attrs = en.fileAttributes;
            if ([attrs[NSFileModificationDate] compare:cutoff] == NSOrderedAscending) continue;
            NSString *key = rel.lastPathComponent;
            [seen addObject:key];
            unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
            unsigned long long offset = [_offsets[key] unsignedLongLongValue];
            if (size <= offset) continue;   // nothing appended (append-only files)
            [self consumeFile:[base stringByAppendingPathComponent:rel] key:key fromOffset:offset];
        }
    }
    // Offsets for files that aged out of the window are dead weight.
    for (NSString *key in _offsets.allKeys) if (![seen containsObject:key]) [_offsets removeObjectForKey:key];
    PruneDays(_days, WeekStartDayString());
}

- (void)consumeFile:(NSString *)path key:(NSString *)key fromOffset:(unsigned long long)offset {
    NSData *chunk = [self newLineDataAtPath:path key:key offsets:_offsets];
    if (!chunk) return;
    NSMutableArray *events = [NSMutableArray array];
    ForEachMatchingLine(chunk, "\"token_count\"", ^(NSString *line) {
        NSDictionary *e = ParseTokenCountLine(line);
        if (e) [events addObject:e];
    });
    if (!events.count) return;
    NSDictionary *acc = AccumulateTokenEvents(_days, events, nil);
    _days = [acc[@"days"] mutableCopy];
    NSString *ts = acc[@"latestTs"];
    if (ts && (!_limitsTs || [ts compare:_limitsTs] == NSOrderedDescending)) {
        _limits = acc[@"latestLimits"];
        _limitsTs = ts;
    }
}

// Claude Code's per-session transcripts carry per-message usage — the only live source
// for today's Claude tokens (~/.claude/stats-cache.json computes through yesterday and
// its aggregation isn't reproducible). Same incremental pattern as the Codex rollouts.
- (void)scanClaudeTranscripts {
    NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@".claude/projects"];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-8 * 24 * 3600];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtPath:base];
    for (NSString *rel in en) {
        if (![rel.pathExtension isEqualToString:@"jsonl"]) continue;
        NSDictionary *attrs = en.fileAttributes;
        if ([attrs[NSFileModificationDate] compare:cutoff] == NSOrderedAscending) continue;
        [seen addObject:rel];
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        if (size <= [_claudeOffsets[rel] unsignedLongLongValue]) continue;
        NSData *chunk = [self newLineDataAtPath:[base stringByAppendingPathComponent:rel]
                                            key:rel offsets:_claudeOffsets];
        if (!chunk) continue;
        NSMutableArray *events = [NSMutableArray array];
        NSMutableSet *seenIds = _claudeSeenIds;
        ForEachMatchingLine(chunk, "\"usage\"", ^(NSString *line) {
            NSDictionary *e = ParseClaudeUsageLine(line);
            if (!e) return;
            NSString *messageId = e[@"id"];
            if (messageId) {   // a message amended across lines must only count once
                if ([seenIds containsObject:messageId]) return;
                [seenIds addObject:messageId];
            }
            [events addObject:e];
        });
        if (events.count)
            _claudeDays = [AccumulateTokenEvents(_claudeDays, events, nil)[@"days"] mutableCopy];
    }
    for (NSString *key in _claudeOffsets.allKeys)
        if (![seen containsObject:key]) [_claudeOffsets removeObjectForKey:key];
    PruneDays(_claudeDays, WeekStartDayString());
    if (_claudeSeenIds.count > 100000) [_claudeSeenIds removeAllObjects];   // bounded; dupes are rare
}

- (NSString *)claudeAccessTokenForNow:(double)now {
    if (_claudeAccessToken.length && (_claudeAccessTokenExpiresAt <= 0 || _claudeAccessTokenExpiresAt > now + 60))
        return _claudeAccessToken;
    if (now < _claudeKeychainNextTry) {
        if (!_claudeAccountStatus.length) _claudeAccountStatus = @"Keychain token unavailable; retrying later";
        return nil;
    }

    NSDictionary *cred = ClaudeAccessTokenFromKeychain();
    NSDictionary *outcome = ClaudeKeychainOutcome(cred != nil, cred[@"token"],
                                                  [cred[@"expiresAt"] doubleValue], now);
    if (![outcome[@"ok"] boolValue]) {
        _claudeAccessToken = nil;
        _claudeAccessTokenExpiresAt = 0;
        _claudeKeychainNextTry = now + [outcome[@"retryDelay"] doubleValue];
        _claudeAccountStatus = outcome[@"status"];
        GBLog("keychain read: %{public}@", outcome[@"status"]);
        return nil;
    }

    _claudeAccessToken = outcome[@"token"];
    _claudeAccessTokenExpiresAt = [outcome[@"expiresAt"] doubleValue];
    _claudeKeychainNextTry = 0;
    GBLog("keychain read: ok");
    return _claudeAccessToken;
}

- (void)rememberClaudeFetchError:(NSDictionary *)fetch now:(double)now {
    BOOL rateLimited = [fetch[@"rateLimited"] boolValue];
    double retry = [fetch[@"retryAfter"] doubleValue];
    NSString *message = [fetch[@"message"] isKindOfClass:NSString.class] ? fetch[@"message"] : nil;
    if (ShouldDropCachedTokenForStatus([fetch[@"statusCode"] integerValue])) {
        _claudeAccessToken = nil;        // revoked; re-read the Keychain next attempt
        _claudeAccessTokenExpiresAt = 0;
    }
    if (rateLimited) {
        _claudeNextFetch = now + RateLimitRetryDelay(retry);
        _claudeAccountStatus = @"Usage API rate-limited; retrying later";
    } else {
        _claudeAccountStatus = message.length ? [@"Usage API: " stringByAppendingString:message]
                                              : @"Usage API unavailable";
    }
}

- (AIUsage *)claudeUsage {
    AIUsage *u = ReadClaudeUsage();   // stats-cache: sessions/messages/models (day-stale)
    if (self.allowClaudeTranscripts) {
        [self scanClaudeTranscripts];
        if (_claudeOffsets.count) {
            NSString *today = LocalDateString(NSDate.date);
            u.todayTokens = [_claudeDays[today][@"f"] longLongValue];
            u.todayTokensAll = [_claudeDays[today][@"t"] longLongValue];
            long long week = 0, weekAll = 0;
            for (NSDictionary *day in _claudeDays.allValues) {
                week += [day[@"f"] longLongValue];
                weekAll += [day[@"t"] longLongValue];
            }
            u.weekTokens = week;
            u.weekTokensAll = weekAll;
            u.available = YES;
            u.stale = NO;   // token counts are live now; only the activity counts lag a day
            u.statusText = @"Tokens live from local transcripts";
            u.source = @"~/.claude transcripts + stats cache";
        }
    } else {
        [_claudeOffsets removeAllObjects];
        [_claudeDays removeAllObjects];
        [_claudeSeenIds removeAllObjects];
        if (u.statusText.length)
            u.statusText = [u.statusText stringByAppendingString:@" · transcript totals off"];
    }

    if (self.useClaudeAccount) {
        double now = NSDate.date.timeIntervalSince1970;
        if (ShouldFetchClaudeAccount(self.useClaudeAccount, self.allowClaudeAccountFetch,
                                     _claudeUsageJSON != nil, _claudeAccountStatus.length > 0,
                                     now, _claudeNextFetch)) {
            _claudeNextFetch = now + 900;   // the endpoint rate-limits readily; 15 min cap
            _lastFetchSkipReason = nil;
            NSString *token = [self claudeAccessTokenForNow:now];
            NSDictionary *fetch = token ? FetchClaudeUsageJSON(token) : nil;
            if ([fetch[@"_glancebarFetchError"] boolValue]) {
                [self rememberClaudeFetchError:fetch now:now];
                GBLog("claude fetch: failed http=%ld rateLimited=%d",
                      (long)[fetch[@"statusCode"] integerValue], [fetch[@"rateLimited"] boolValue]);
            } else if (fetch && !fetch[@"error"]) {
                _claudeUsageJSON = fetch;
                _claudeAccountStatus = nil;
                GBLog("claude fetch: ok");
            } else if (token.length) {
                _claudeAccountStatus = @"Usage API unavailable";
                GBLog("claude fetch: unusable response");
            }
        } else {
            NSString *skip = !self.allowClaudeAccountFetch ? @"hidden" : @"throttled";
            if (![skip isEqualToString:_lastFetchSkipReason]) {
                GBLog("claude fetch: skipped (%{public}@)", skip);
                _lastFetchSkipReason = skip;
            }
        }
        NSDictionary *extraStatus = ClaudeExtraUsageStatus(_claudeUsageJSON);
        if (extraStatus[@"description"]) u.extraUsage = extraStatus[@"description"];

        NSDictionary *pick = PickClaudeLimitWindow(_claudeUsageJSON, NSDate.date.timeIntervalSince1970);
        if (pick) {
            u.limitStatusAvailable = YES;
            u.remainingFraction = [pick[@"remainingFraction"] doubleValue];
            NSNumber *resets = pick[@"resetsAt"];
            if (resets) u.resetText = ResetTextFromDate([NSDate dateWithTimeIntervalSince1970:resets.doubleValue]);
            u.statusReason = [NSString stringWithFormat:@"%@ window · your Claude account", pick[@"window"]];
            u.statusSource = @"Anthropic usage API (opt-in)";
        } else {
            NSString *fallback = _claudeUsageJSON ? @"Claude account response did not include a current limit window"
                : self.allowClaudeAccountFetch ? @"Claude account status unavailable"
                : @"Claude account refresh paused until visible";
            u.statusReason = _claudeAccountStatus ?: (extraStatus[@"statusReason"] ?: fallback);
        }
        if ([extraStatus[@"overageActive"] boolValue]) {
            u.limitStatusAvailable = YES;
            u.remainingFraction = 0;
            u.overageActive = YES;
            u.resetText = @"Not provided";
            u.statusReason = extraStatus[@"statusReason"];
            u.statusSource = @"Anthropic usage API (opt-in)";
        }
        u.diagnostics = [NSString stringWithFormat:@"usage JSON %@ · next fetch %@ · keychain %@",
            _claudeUsageJSON ? @"cached" : @"none",
            FmtEpochClock(_claudeNextFetch),
            _claudeKeychainNextTry > now
                ? [@"backoff until " stringByAppendingString:FmtEpochClock(_claudeKeychainNextTry)]
                : _claudeAccessToken.length ? @"token cached" : @"not read"];
    } else {
        _claudeAccessToken = nil;
        _claudeAccessTokenExpiresAt = 0;
        _claudeUsageJSON = nil;
        _claudeAccountStatus = nil;
        _claudeNextFetch = 0;
        u.diagnostics = @"account toggle off";
    }
    return u;
}

// Session counts, per-model split, and last activity still come from the sqlite thread
// store (the rollouts don't carry the model); re-queried only when the db changes.
- (void)refreshDBExtras {
    NSString *path = CodexStatePath();
    if (!path) { _sessionsToday = 0; _models = @[]; _lastActivity = nil; return; }
    NSDate *m1 = FileMTime(path), *m2 = FileMTime([path stringByAppendingString:@"-wal"]);
    NSDate *stamp = (m2 && (!m1 || [m2 compare:m1] == NSOrderedDescending)) ? m2 : m1;
    NSString *today = LocalDateString(NSDate.date);
    if (_dbStamp && stamp && [stamp isEqualToDate:_dbStamp] && [today isEqualToString:_dbDay]) return;
    _dbStamp = stamp;
    _dbDay = today;

    long long todayEpoch = (long long)StartOfLocalDay(NSDate.date).timeIntervalSince1970;
    NSString *todaySQL = [NSString stringWithFormat:
        @"select count(*), coalesce(max(updated_at),0) from threads where updated_at >= %lld;", todayEpoch];
    NSArray<NSString *> *fields = SQLiteFields([[RunSQLite(path, todaySQL)
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        componentsSeparatedByString:@"\n"].firstObject);
    _sessionsToday = fields.count >= 1 ? [fields[0] longLongValue] : 0;
    long long last = fields.count >= 2 ? [fields[1] longLongValue] : 0;
    _lastActivity = last > 0 ? [NSDate dateWithTimeIntervalSince1970:last] : nil;

    // Sessions per model are accurate; per-model token sums would be lifetime-inflated,
    // so deliberately don't fetch them.
    NSDate *weekStart = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-6
                                                              toDate:StartOfLocalDay(NSDate.date) options:0];
    NSString *modelsSQL = [NSString stringWithFormat:
        @"select coalesce(nullif(model,''),'unknown'), count(*) from threads "
         "where updated_at >= %lld group by 1 order by 2 desc limit 5;",
        (long long)weekStart.timeIntervalSince1970];
    NSMutableArray *models = [NSMutableArray array];
    for (NSString *line in [RunSQLite(path, modelsSQL) componentsSeparatedByString:@"\n"]) {
        NSArray<NSString *> *cols = SQLiteFields([line stringByTrimmingCharactersInSet:
                                                  NSCharacterSet.whitespaceAndNewlineCharacterSet]);
        if (cols.count < 2 || !cols[0].length) continue;
        [models addObject:@{@"name": cols[0], @"sessions": @([cols[1] longLongValue])}];
    }
    _models = models;
}

- (AIUsage *)codexUsage {
    [self scanRollouts];
    [self refreshDBExtras];

    AIUsage *u = [AIUsage new];
    u.name = @"Codex";
    u.source = @"~/.codex session logs";
    u.remainingFraction = -1;
    u.resetText = @"Not exposed locally";
    u.models = _models ?: @[];
    u.available = _offsets.count > 0;
    if (!u.available) {
        u.statusText = @"Local state not found";
        u.statusReason = @"No Codex session logs under ~/.codex";
        return u;
    }
    u.statusText = @"Per-turn session logs";
    double now = NSDate.date.timeIntervalSince1970;
    NSString *today = LocalDateString(NSDate.date);
    u.todayTokens = [_days[today][@"f"] longLongValue];       // fresh = the headline
    u.todayTokensAll = [_days[today][@"t"] longLongValue];
    long long week = 0, weekAll = 0;
    for (NSDictionary *day in _days.allValues) {              // _days is pruned to 7 days
        week += [day[@"f"] longLongValue];
        weekAll += [day[@"t"] longLongValue];
    }
    u.weekTokens = week;
    u.weekTokensAll = weekAll;
    u.todaySessions = _sessionsToday;
    u.lastActivity = _lastActivity;
    if (u.models.count) u.topModel = u.models.firstObject[@"name"];

    NSDictionary *pick = PickLimitWindow(_limits, now);
    if (pick) {
        u.limitStatusAvailable = YES;
        u.remainingFraction = [pick[@"remainingFraction"] doubleValue];
        NSNumber *resets = pick[@"resetsAt"];
        if (resets) u.resetText = ResetTextFromDate([NSDate dateWithTimeIntervalSince1970:resets.doubleValue]);
        NSString *plan = [pick[@"plan"] isKindOfClass:NSString.class] ? pick[@"plan"] : nil;
        u.statusReason = plan.length
            ? [NSString stringWithFormat:@"%@ window · %@ plan", pick[@"window"], plan]
            : [NSString stringWithFormat:@"%@ window", pick[@"window"]];
        u.statusSource = @"~/.codex session logs";
    }
    else u.statusReason = CodexLimitStatusReason(_limits, _limitsTs, now);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"limits snapshot %@",
                      _limitsTs.length ? _limitsTs : @"never seen"]];
    BOOL anyCurrent = NO, anyUsable = NO;
    for (NSString *key in @[@"primary", @"secondary"]) {
        NSDictionary *w = [_limits[key] isKindOfClass:NSDictionary.class] ? _limits[key] : nil;
        if (![w[@"used_percent"] isKindOfClass:NSNumber.class]) continue;
        anyUsable = YES;
        double resets = [w[@"resets_at"] doubleValue];
        BOOL expired = resets > 0 && resets <= now;
        if (!expired) anyCurrent = YES;
        long mins = [w[@"window_minutes"] longValue];
        [parts addObject:[NSString stringWithFormat:@"%@ reset %@%@",
            mins == 10080 ? @"weekly" : mins == 300 ? @"5h" : @"window",
            FmtEpochDayClock(resets), expired ? @" (expired)" : @""]];
    }
    if (anyUsable && !anyCurrent) [parts addObject:@"all expired"];
    u.diagnostics = [parts componentsJoinedByString:@" · "];
    return u;
}

- (NSArray<AIUsage *> *)read {
    NSArray<AIUsage *> *usage = @[[self claudeUsage], [self codexUsage]];
    NSString *statusPath = [NSHomeDirectory() stringByAppendingPathComponent:@".glancebar/ai-status.json"];
    NSDictionary *status = JSONDictionaryAtPath(statusPath);
    if (status) {
        for (AIUsage *u in usage) ApplyAIStatusFile(u, status, @"~/.glancebar/ai-status.json");
    }
    for (AIUsage *u in usage) {
        NSString *prev = _lastStatusReasons[u.name];
        if (u.statusReason.length && ![u.statusReason isEqualToString:prev]) {
            // Reason strings can carry server- or status-file-sourced text, so they stay
            // private by os_log default; only the provider name is logged publicly.
            GBLog("%{public}@ status changed: %@ -> %@",
                  u.name, prev ?: @"(none)", u.statusReason);
            _lastStatusReasons[u.name] = u.statusReason;
        }
    }
    return usage;
}

@end

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

static NSColor *BarIconTrackColor(NSColor *fg) {
    return [fg colorWithAlphaComponent:0.25];
}

static NSImage *DriveMeterIcon(double fraction, NSColor *fg, NSColor *fill) {
    CGFloat w = 17, h = 14;
    fraction = MIN(1.0, MAX(0.0, fraction));
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [img lockFocus];

    NSRect body = NSMakeRect(1.5, 3.0, 14.0, 9.0);
    NSBezierPath *outer = [NSBezierPath bezierPathWithRoundedRect:body xRadius:2.2 yRadius:2.2];
    [BarIconTrackColor(fg) setFill];
    [outer fill];

    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(body, 1.2, 1.2) xRadius:1.2 yRadius:1.2];
    [NSGraphicsContext saveGraphicsState];
    [clip addClip];
    [(fill ?: fg) setFill];
    NSRect fillRect = NSInsetRect(body, 1.2, 1.2);
    fillRect.size.width *= fraction;
    NSRectFill(fillRect);
    [NSGraphicsContext restoreGraphicsState];

    [fg setStroke];
    outer.lineWidth = 1.2;
    [outer stroke];
    [[fg colorWithAlphaComponent:0.75] setStroke];
    NSBezierPath *slot = [NSBezierPath bezierPath];
    [slot moveToPoint:NSMakePoint(5.0, 5.0)];
    [slot lineToPoint:NSMakePoint(12.0, 5.0)];
    slot.lineWidth = 1.0;
    [slot stroke];

    [img unlockFocus];
    img.template = NO;
    return img;
}

static NSImage *BatteryMeterIcon(BatteryState b, NSColor *fg, NSColor *fill) {
    CGFloat w = 24, h = 14;
    double fraction = b.valid ? MIN(1.0, MAX(0.0, b.percent / 100.0)) : 0.0;
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [img lockFocus];

    NSRect body = NSMakeRect(1.5, 3.0, 18.0, 8.0);
    NSBezierPath *outer = [NSBezierPath bezierPathWithRoundedRect:body xRadius:2.0 yRadius:2.0];
    [BarIconTrackColor(fg) setFill];
    [outer fill];

    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(body, 1.4, 1.4) xRadius:1.0 yRadius:1.0];
    [NSGraphicsContext saveGraphicsState];
    [clip addClip];
    [(fill ?: fg) setFill];
    NSRect fillRect = NSInsetRect(body, 1.4, 1.4);
    fillRect.size.width *= fraction;
    NSRectFill(fillRect);
    [NSGraphicsContext restoreGraphicsState];

    [fg setStroke];
    outer.lineWidth = 1.2;
    [outer stroke];
    NSBezierPath *cap = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(20.2, 5.0, 2.3, 4.0)
                                                        xRadius:0.8 yRadius:0.8];
    [fg setFill];
    [cap fill];

    if (b.valid && b.acConnected) {
        NSBezierPath *bolt = [NSBezierPath bezierPath];
        [bolt moveToPoint:NSMakePoint(11.6, 10.2)];
        [bolt lineToPoint:NSMakePoint(8.8, 6.5)];
        [bolt lineToPoint:NSMakePoint(11.0, 6.5)];
        [bolt lineToPoint:NSMakePoint(9.7, 3.8)];
        [bolt lineToPoint:NSMakePoint(14.1, 8.0)];
        [bolt lineToPoint:NSMakePoint(11.8, 8.0)];
        [bolt closePath];
        [[NSColor colorWithWhite:0 alpha:0.38] setFill];
        [bolt fill];
    }

    [img unlockFocus];
    img.template = NO;
    return img;
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
        NSImage *customImage = [seg[@"image"] isKindOfClass:NSImage.class] ? seg[@"image"] : nil;
        NSImage *sym = customImage ?: (symbol.length ? TintedSymbol(symbol, var ? var.doubleValue : -1, pt, fg) : nil);
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
    CFAbsoluteTime _cpuBaselineTime;
    double _lastCPU;
    BOOL _lastCPUValid;
    NSArray<AIUsage *> *_aiUsage;
    AIReader *_aiReader;            // touched only on _aiQueue
    dispatch_queue_t _aiQueue;
    BOOL _aiLoading, _aiRefreshPending;
    NSString *_aiSignature;
    NSArray<NSDictionary *> *_hogs;
    NSArray<NSDictionary *> *_topCPU, *_topMem;
    NSMutableArray<NSNumber *> *_ampHistory;
    NSUInteger _sampleGen;
    CFAbsoluteTime _lastSampleTime;
    BOOL _showWatts, _showHealth, _hogsLoading, _hogsUnavailable;
    BOOL _barShowDisk, _barShowBattery, _barShowSystem, _barShowAI;
    BOOL _aiGatesLogged, _lastShowAI, _lastUseAccount, _lastAllowTranscripts;
    BOOL _procStatsLoading, _procStatsUnavailable;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud registerDefaults:@{@"showWatts": @YES, @"showHealth": @YES,
                           @"barShowDisk": @YES, @"barShowBattery": @YES,
                           @"barShowSystem": @NO, @"barShowAI": @NO,
                           @"useClaudeAccount": @NO, @"useClaudeTranscripts": @NO}];
    _showWatts = [ud boolForKey:@"showWatts"];
    _showHealth = [ud boolForKey:@"showHealth"];
    _barShowDisk = [ud boolForKey:@"barShowDisk"];
    _barShowBattery = [ud boolForKey:@"barShowBattery"];
    _barShowSystem = [ud boolForKey:@"barShowSystem"];
    _barShowAI = [ud boolForKey:@"barShowAI"];
    _ampHistory = [NSMutableArray array];
    _aiUsage = @[];
    _aiReader = [AIReader new];
    _aiQueue = dispatch_queue_create("com.iantodd.glancebar.ai", DISPATCH_QUEUE_SERIAL);
    _hogs = @[];
    _topCPU = @[];
    _topMem = @[];

    // LSUIElement apps have no visible menu bar, but key equivalents are still routed
    // through the main menu — without this, Cmd+W is dead in the details window.
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *fileItem = [mainMenu addItemWithTitle:@"File" action:nil keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    fileItem.submenu = fileMenu;
    NSApp.mainMenu = mainMenu;

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
    // refresh fires from three uncoordinated sources (15s timer, IOPS notification
    // bursts, popover open); only advance the CPU tick baseline when the window is
    // wide enough to be meaningful, and reuse the last good reading otherwise.
    double nowT = CFAbsoluteTimeGetCurrent();
    BOOL advance = nowT - _cpuBaselineTime >= 2.0;
    SystemState s = ReadSystemState(advance ? &_cpuPrev : NULL);
    if (advance) _cpuBaselineTime = nowT;
    if (s.cpuValid) { _lastCPU = s.cpu; _lastCPUValid = YES; }
    else if (_lastCPUValid) { s.cpu = _lastCPU; s.cpuValid = YES; }
    _sys = s;
    [self refreshAIUsageAsync];
    if (_bat.valid) {
        [_ampHistory addObject:@(_bat.amperage_mA)];
        while (_ampHistory.count > 6) [_ampHistory removeObjectAtIndex:0];
    }
    [self updateBar];
    if (_popover.isShown) [self rebuildContent];
    if (_detailsWindow.isVisible) [self rebuildDetails];
    // The details window stays open indefinitely; refresh its one-shot process samples
    // on a slow cadence so they don't masquerade as live data next to live numbers.
    if (_detailsWindow.isVisible && !_hogsLoading && !_procStatsLoading &&
        CFAbsoluteTimeGetCurrent() - _lastSampleTime >= 30)
        [self beginSampling];
}

// AI state lives in local files plus sqlite child processes — never read it on the
// main thread (refresh fires every 15s and on IOPS bursts). Single-flight: a tick
// that arrives mid-read is skipped; the next one catches up.
- (void)refreshAIUsageAsync {
    if (_aiLoading) { _aiRefreshPending = YES; return; }
    _aiLoading = YES;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL showAI = _barShowAI || _popover.isShown || _detailsWindow.isVisible;
    BOOL useAccount = [ud boolForKey:@"useClaudeAccount"];
    BOOL allowAccountFetch = showAI && useAccount;
    BOOL allowTranscripts = [ud boolForKey:@"useClaudeTranscripts"];
    if (!_aiGatesLogged || showAI != _lastShowAI || useAccount != _lastUseAccount ||
        allowTranscripts != _lastAllowTranscripts) {
        GBLog("gates: showAI=%d useClaudeAccount=%d transcripts=%d",
              showAI, useAccount, allowTranscripts);
        _aiGatesLogged = YES; _lastShowAI = showAI;
        _lastUseAccount = useAccount; _lastAllowTranscripts = allowTranscripts;
    }
    dispatch_async(_aiQueue, ^{
        self->_aiReader.useClaudeAccount = useAccount;
        self->_aiReader.allowClaudeAccountFetch = allowAccountFetch;
        self->_aiReader.allowClaudeTranscripts = allowTranscripts;
        NSArray<AIUsage *> *usage = [self->_aiReader read];
        NSMutableString *sig = [NSMutableString string];
        for (AIUsage *u in usage)
            [sig appendFormat:@"%@|%d|%d|%lld|%lld|%lld|%lld|%.4f|%@|%@|%@;", u.name, u.available,
             u.limitStatusAvailable, u.todayTokens, u.todayTokensAll, u.weekTokens, u.todaySessions,
             u.remainingFraction, u.resetText, u.statusText, u.statusReason];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_aiLoading = NO;
            BOOL rerun = self->_aiRefreshPending;
            self->_aiRefreshPending = NO;
            self->_aiUsage = usage;
            if (![sig isEqualToString:self->_aiSignature]) {
                self->_aiSignature = sig;
                [self updateBar];
                if (self->_popover.isShown) [self rebuildContent];
                if (self->_detailsWindow.isVisible) [self rebuildDetails];
            }
            if (rerun) [self refreshAIUsageAsync];
        });
    });
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
        NSColor *driveTextColor = frac >= 0.85 ? DiskColor(frac) : fg;
        [segments addObject:@{@"image": DriveMeterIcon(frac, fg, fg),
                              @"text": [NSString stringWithFormat:@"%d%%", pct],
                              @"color": driveTextColor}];
    }
    if (_barShowBattery) {
        NSString *text = _bat.valid ? [NSString stringWithFormat:@"%d%%", _bat.percent] : @"—";
        NSColor *color = _bat.valid && _bat.percent <= 20 && !_bat.acConnected ? BattBarColor(_bat.percent) : fg;
        NSMutableDictionary *seg = [@{@"text": text, @"color": color} mutableCopy];
        if (_bat.valid) {   // no battery (desktop Mac): text-only, no misleading empty glyph
            NSColor *fill = (_bat.percent <= 20 && !_bat.acConnected) ? BattBarColor(_bat.percent) : fg;
            seg[@"image"] = BatteryMeterIcon(_bat, fg, fill);
        }
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
    // Reset the content view so the rebuild starts at the top on a fresh open.
    _popover.contentViewController.view = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,kW,10)];
    [self refresh];
    [self rebuildContent];
    [_popover showRelativeToRect:_item.button.bounds ofView:_item.button preferredEdge:NSMaxYEdge];
    [self refreshAIUsageAsync];
    [self beginSampling];
}

// Starts both process samplers, invalidating any still-in-flight results: top takes
// >1s, so a close/reopen can otherwise interleave an old sample over a newer one.
- (void)beginSampling {
    _sampleGen++;
    _lastSampleTime = CFAbsoluteTimeGetCurrent();
    [self sampleHogsAsync];
    [self sampleProcessStatsAsync];
}

- (void)sampleHogsAsync {
    NSUInteger gen = _sampleGen;
    _hogs = @[];
    _hogsLoading = YES;
    _hogsUnavailable = NO;
    if (_popover.isShown) [self rebuildContent];
    if (_detailsWindow.isVisible) [self rebuildDetails];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *hogs = SampleHogs(5);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_sampleGen) return;   // superseded by a newer sampling pass
            self->_hogs = hogs ? hogs : @[];
            self->_hogsLoading = NO;
            self->_hogsUnavailable = self->_hogs.count == 0;
            if (self->_popover.isShown) [self rebuildContent];
            if (self->_detailsWindow.isVisible) [self rebuildDetails];
        });
    });
}

- (void)sampleProcessStatsAsync {
    NSUInteger gen = _sampleGen;
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
            if (gen != self->_sampleGen) return;   // superseded by a newer sampling pass
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
    if (u.overageActive && u.statusReason.length) return u.statusReason;
    if (u.limitStatusAvailable) return [self compactResetText:u];
    if (!u.available) return @"No local state";
    if (u.statusReason.length) return u.statusReason;
    if (u.stale && u.statusText.length)   // e.g. Claude's cache computes through yesterday
        return [NSString stringWithFormat:@"No limit status · %@", u.statusText];
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
    CGFloat rightW = 70;
    CGFloat titleW = 74;
    CGFloat barX = pad + titleW + 8;
    CGFloat barW = inner - titleW - rightW - 18;
    BOOL hasGauge = u.limitStatusAvailable && u.remainingFraction >= 0;
    NSString *title = u.name ?: @"AI";
    [row addSubview:[self text:title font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold] color:nil
                          at:NSMakeRect(pad, 25, titleW, 15) align:NSTextAlignmentLeft]];
    // "left" makes the direction unambiguous — a bare "10%" reads as used just as
    // easily as remaining.
    NSString *rightText = hasGauge ? [[self aiPercentText:u] stringByAppendingString:@" left"] : @"—";
    [row addSubview:[self text:rightText font:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold]
                         color:[self aiStatusColor:u] at:NSMakeRect(width-pad-rightW, 23, rightW, 17) align:NSTextAlignmentRight]];
    if (hasGauge) {   // no gauge at all beats an empty gauge that implies "0% used"
        Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(barX, 28, MAX(20, barW), 7)];
        g.fraction = u.remainingFraction;
        g.color = [self aiStatusColor:u];
        [row addSubview:g];
    }
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
        NSView *hl = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, 50)];
        CGFloat inner = kW - 2*kPad;
        [hl addSubview:[self text:big font:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold] color:nil
                             at:NSMakeRect(kPad, 28, inner, 20) align:NSTextAlignmentLeft]];
        [hl addSubview:[self text:sub font:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor
                             at:NSMakeRect(kPad, 13, inner, 14) align:NSTextAlignmentLeft]];
        Gauge *chargeGauge = [[Gauge alloc] initWithFrame:NSMakeRect(kPad, 4, inner, 5)];
        chargeGauge.fraction = _bat.percent / 100.0;
        chargeGauge.color = BattBarColor(_bat.percent);
        [hl addSubview:chargeGauge];
        [root addSubview:hl]; y += 54;
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
            double share = GroupCPUShare(h);
            NSDictionary *info = ProcessDisplayInfo(h);
            NSString *right = [NSString stringWithFormat:@"CPU %d%%", (int)lround(share * 100)];
            [root addSubview:[self compactSignalRow:info[@"title"] right:right fraction:MIN(share, 1.0)
                                              color:CPUColor(share) width:kW pad:kPad at:y]];
            y += 30;
            // ps cannot see kernel_task, which dominates exactly when throttling.
            double rowShare = 0;
            for (NSDictionary *row in _topCPU) rowShare += GroupCPUShare(row);
            if (_sys.cpuValid && _sys.cpu >= 0.5 && _sys.cpu > 2.0 * rowShare) {
                [root addSubview:[self text:@"Mostly system-level work (kernel)"
                                       font:[NSFont systemFontOfSize:10.5] color:NSColor.secondaryLabelColor
                                         at:NSMakeRect(kPad, y, inner, 13) align:NSTextAlignmentLeft]];
                y += 18;
            }
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
        // Preserve the scroll position across the periodic rebuilds; togglePopover
        // resets the content view on open so a fresh popover still starts at the top.
        CGFloat offset = 0;
        NSView *current = _popover.contentViewController.view;
        if ([current isKindOfClass:NSScrollView.class])
            offset = ((NSScrollView *)current).contentView.bounds.origin.y;
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, kW, maxPopoverH)];
        scroll.borderType = NSNoBorder;
        scroll.drawsBackground = NO;
        scroll.hasVerticalScroller = YES;
        scroll.autohidesScrollers = YES;
        scroll.documentView = root;
        [scroll.contentView scrollToPoint:NSMakePoint(0, MIN(offset, MAX(0, y - maxPopoverH)))];
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
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *transcripts = [m addItemWithTitle:@"Claude transcript token totals"
                                           action:@selector(toggleClaudeTranscripts:) keyEquivalent:@""];
    transcripts.target = self;
    transcripts.state = [NSUserDefaults.standardUserDefaults boolForKey:@"useClaudeTranscripts"]
        ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *acct = [m addItemWithTitle:@"Claude account via Keychain/API"
                                    action:@selector(toggleClaudeAccount:) keyEquivalent:@""];
    acct.target = self;
    acct.state = [NSUserDefaults.standardUserDefaults boolForKey:@"useClaudeAccount"]
        ? NSControlStateValueOn : NSControlStateValueOff;
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height) inView:sender];
}

// Opt-in: reads the Claude Code OAuth token from the Keychain (macOS will ask once)
// and polls Anthropic's usage endpoint for the real limit gauge. Off by default.
- (void)toggleClaudeAccount:(id)s {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setBool:![ud boolForKey:@"useClaudeAccount"] forKey:@"useClaudeAccount"];
    [self refresh];
}
- (void)toggleClaudeTranscripts:(id)s {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setBool:![ud boolForKey:@"useClaudeTranscripts"] forKey:@"useClaudeTranscripts"];
    [self refresh];
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
    [self refreshAIUsageAsync];
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
            double share = GroupCPUShare(h);
            [root addSubview:[self processMetricRow:h right:[NSString stringWithFormat:@"CPU %d%%", (int)lround(share * 100)]
                                           fraction:MIN(share, 1.0) color:CPUColor(share)
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
        [root addSubview:[self compactSignalRow:@"Charge level"
                                          right:[NSString stringWithFormat:@"%d%%", _bat.percent]
                                       fraction:_bat.percent / 100.0
                                          color:BattBarColor(_bat.percent)
                                          width:kDetailW pad:kDetailPad at:y]];
        y += 34;
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
        if (u.extraUsage)
            [self addDetailKey:@"Extra usage" value:u.extraUsage to:root y:&y width:kDetailW];
        if (u.statusSource)
            [self addDetailKey:@"Status source" value:u.statusSource to:root y:&y width:kDetailW];
    }

    [self addDetailHeading:@"Privacy & Sources" to:root y:&y width:kDetailW];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [self addDetailKey:@"Claude account"
                 value:[ud boolForKey:@"useClaudeAccount"] ? @"On · Keychain token + api.anthropic.com" : @"Off · no Keychain/API access"
                    to:root y:&y width:kDetailW];
    [self addDetailKey:@"Claude transcripts"
                 value:[ud boolForKey:@"useClaudeTranscripts"] ? @"On · local ~/.claude/projects JSONL" : @"Off · transcripts not read"
                    to:root y:&y width:kDetailW];
    [self addDetailKey:@"Codex logs" value:@"On · local ~/.codex session JSONL"
                    to:root y:&y width:kDetailW];
    NSString *statusPath = [NSHomeDirectory() stringByAppendingPathComponent:@".glancebar/ai-status.json"];
    NSString *statusState = [NSFileManager.defaultManager fileExistsAtPath:statusPath]
        ? @"Present · overrides provider gauges" : @"Not found";
    [self addDetailKey:@"Status file" value:statusState to:root y:&y width:kDetailW];

    [self addDetailHeading:@"Local History" to:root y:&y width:kDetailW];
    for (AIUsage *u in _aiUsage) {
        [self addDetailHeading:u.name ?: @"AI" to:root y:&y width:kDetailW];
        if (!u.available) {
            [self addDetailStatus:u.statusText ?: @"Local state not found" to:root y:&y width:kDetailW];
            [self addDetailKey:@"Source" value:u.source ?: @"unknown" to:root y:&y width:kDetailW];
            continue;
        }
        NSString *todayVal = u.todayTokens > 0 ? FmtTokenCount(u.todayTokens) : @"No local usage today";
        if (u.todayTokensAll > u.todayTokens)
            todayVal = [todayVal stringByAppendingFormat:@" · %@ incl. cached context", FmtCompact(u.todayTokensAll)];
        [self addDetailKey:@"Today" value:todayVal to:root y:&y width:kDetailW];
        NSString *weekVal = u.weekTokens > 0 ? FmtTokenCount(u.weekTokens) : @"No local usage";
        if (u.weekTokensAll > u.weekTokens)
            weekVal = [weekVal stringByAppendingFormat:@" · %@ incl. cached context", FmtCompact(u.weekTokensAll)];
        [self addDetailKey:@"7 days" value:weekVal to:root y:&y width:kDetailW];
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
        if (u.lastActivity)   // file/db activity time — distinct from "stats computed through"
            [self addDetailKey:@"State updated" value:ClockText(u.lastActivity) to:root y:&y width:kDetailW];
        [self addDetailKey:@"Source" value:u.source ?: @"unknown" to:root y:&y width:kDetailW];

        if (u.models.count) {
            [self addDetailHeading:@"Models" to:root y:&y width:kDetailW];
            for (NSDictionary *model in u.models) {
                NSString *name = ShortModelName(model[@"name"]);
                long long tokens = [model[@"tokens"] isKindOfClass:NSNumber.class] ? [model[@"tokens"] longLongValue] : 0;
                NSNumber *sessions = [model[@"sessions"] isKindOfClass:NSNumber.class] ? model[@"sessions"] : nil;
                NSString *right = tokens > 0 && sessions ? [NSString stringWithFormat:@"%@ · %@ sessions", FmtTokenCount(tokens), sessions]
                                : sessions ? [NSString stringWithFormat:@"%@ sessions", sessions]
                                : FmtTokenCount(tokens);
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
            double share = GroupCPUShare(h);
            NSString *right = [NSString stringWithFormat:@"%d%%", (int)lround(share * 100)];
            [root addSubview:[self processMetricRow:h right:right fraction:MIN(share, 1.0)
                                              color:CPUColor(share) width:kDetailW pad:kDetailPad at:y]];
            y += 42;
        }
        double rowShare = 0;
        for (NSDictionary *row in _topCPU) rowShare += GroupCPUShare(row);
        if (_sys.cpuValid && _sys.cpu >= 0.5 && _sys.cpu > 2.0 * rowShare)
            [self addDetailStatus:@"Headline CPU is mostly system-level work (kernel), which per-app sampling can't see"
                               to:root y:&y width:kDetailW];
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

- (NSScrollView *)detailViewForIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:@"overview"]) return [self overviewDetailsView];
    if ([identifier isEqualToString:@"battery"]) return [self batteryDetailsView];
    if ([identifier isEqualToString:@"system"]) return [self systemDetailsView];
    if ([identifier isEqualToString:@"ai"]) return [self aiDetailsView];
    return nil;
}

- (void)rebuildDetails {
    if (!_detailsWindow) return;

    NSTabView *tabs = nil;
    for (NSView *subview in _detailsWindow.contentView.subviews) {
        if ([subview isKindOfClass:NSTabView.class]) { tabs = (NSTabView *)subview; break; }
    }

    if (!tabs) {   // first build: create the shell once
        NSRect bounds = _detailsWindow.contentView ? _detailsWindow.contentView.bounds : NSMakeRect(0, 0, 660, 520);
        if (bounds.size.width < 100 || bounds.size.height < 100) bounds = NSMakeRect(0, 0, 660, 520);
        NSView *content = [[NSView alloc] initWithFrame:bounds];
        tabs = [[NSTabView alloc] initWithFrame:NSInsetRect(content.bounds, 12, 12)];
        tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [tabs addTabViewItem:[self detailTabWithIdentifier:@"overview" title:@"Overview" view:[self detailViewForIdentifier:@"overview"]]];
        [tabs addTabViewItem:[self detailTabWithIdentifier:@"battery" title:@"Battery" view:[self detailViewForIdentifier:@"battery"]]];
        [tabs addTabViewItem:[self detailTabWithIdentifier:@"system" title:@"System" view:[self detailViewForIdentifier:@"system"]]];
        [tabs addTabViewItem:[self detailTabWithIdentifier:@"ai" title:@"AI" view:[self detailViewForIdentifier:@"ai"]]];
        [content addSubview:tabs];
        _detailsWindow.contentView = content;
        return;
    }

    // Periodic refresh: swap each tab's document in place — the tab view, selection,
    // first responder, and per-tab scroll position all survive.
    for (NSTabViewItem *item in tabs.tabViewItems) {
        NSScrollView *fresh = [self detailViewForIdentifier:item.identifier];
        if (!fresh) continue;
        CGFloat offset = 0;
        if ([item.view isKindOfClass:NSScrollView.class])
            offset = ((NSScrollView *)item.view).contentView.bounds.origin.y;
        item.view = fresh;
        CGFloat maxOffset = MAX(0, fresh.documentView.frame.size.height - fresh.contentView.bounds.size.height);
        [fresh.contentView scrollToPoint:NSMakePoint(0, MIN(offset, maxOffset))];
        [fresh reflectScrolledClipView:fresh.contentView];
    }
}

- (void)showDetails:(id)sender {
    [self refresh];
    BOOL didCreateWindow = (_detailsWindow == nil);
    if (!_detailsWindow) {
        _detailsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 660, 520)
                                                     styleMask:(NSWindowStyleMaskTitled |
                                                                NSWindowStyleMaskClosable |
                                                                NSWindowStyleMaskMiniaturizable |
                                                                NSWindowStyleMaskResizable)
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
        _detailsWindow.title = @"Glancebar Details";
        _detailsWindow.releasedWhenClosed = NO;
        // Tab content is laid out at a fixed 600pt; below ~648 the right column clips
        // with no horizontal scroller, so don't allow narrower.
        _detailsWindow.minSize = NSMakeSize(648, 420);
    }
    [self rebuildDetails];
    if (didCreateWindow) [_detailsWindow center];
    [_detailsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [_popover close];
    [self refreshAIUsageAsync];
    [self beginSampling];
}

@end

#pragma mark - main

static void Dump(BOOL allowOnline) {
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
            printf("  %3.0f%%  %-18s %s\n", GroupCPUShare(h) * 100,
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

    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    printf("ai toggles: barShowAI=%s · useClaudeAccount=%s · useClaudeTranscripts=%s\n",
           [ud boolForKey:@"barShowAI"] ? "on" : "off",
           [ud boolForKey:@"useClaudeAccount"] ? "on" : "off",
           [ud boolForKey:@"useClaudeTranscripts"] ? "on" : "off");
    printf("ai status:\n");
    AIReader *reader = [AIReader new];
    reader.useClaudeAccount = allowOnline && [ud boolForKey:@"useClaudeAccount"];
    reader.allowClaudeAccountFetch = reader.useClaudeAccount;
    reader.allowClaudeTranscripts = [ud boolForKey:@"useClaudeTranscripts"];
    for (AIUsage *u in [reader read]) {
        NSString *remaining = u.limitStatusAvailable ? [NSString stringWithFormat:@"%d%% remaining",
                                                         (int)lround(u.remainingFraction * 100)]
                                                      : @"remaining unavailable";
        NSString *reset = @"reset unavailable";
        if (u.limitStatusAvailable) {
            reset = (u.resetText.length && ![u.resetText isEqualToString:@"Not exposed locally"])
                ? [NSString stringWithFormat:@"resets %@", u.resetText] : @"reset not provided";
        }
        NSString *today = FmtTokenCount(u.todayTokens);
        if (u.todayTokensAll > u.todayTokens)
            today = [today stringByAppendingFormat:@" (%@ incl. cached)", FmtCompact(u.todayTokensAll)];
        NSString *week = FmtTokenCount(u.weekTokens);
        if (u.weekTokensAll > u.weekTokens)
            week = [week stringByAppendingFormat:@" (%@ incl. cached)", FmtCompact(u.weekTokensAll)];
        NSString *reason = ((!u.limitStatusAvailable || u.overageActive) && u.statusReason.length)
            ? [@" · " stringByAppendingString:u.statusReason] : @"";
        printf("  %-7s %s · %s · today %s · 7d %s%s\n",
               u.name.UTF8String,
               remaining.UTF8String,
               reset.UTF8String,
               today.UTF8String,
               week.UTF8String,
               reason.UTF8String);
        if (u.diagnostics.length) printf("          why: %s\n", u.diagnostics.UTF8String);
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--dump") == 0) {
            BOOL allowOnline = getenv("GLANCEBAR_ALLOW_ACCOUNT") != NULL;
            for (int i = 2; i < argc; i++)
                if (strcmp(argv[i], "--online") == 0) allowOnline = YES;
            Dump(allowOnline);
            return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        Controller *c = [Controller new];
        app.delegate = c;
        [app run];
    }
    return 0;
}
