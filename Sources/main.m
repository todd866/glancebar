// Glancebar — one configurable menu bar item at a glance. Click for a native popover
// with storage, battery, system, and AI summaries plus a deeper details window.
// Single-file Objective-C/AppKit. Zero dependencies, no sudo. Pure logic in pure.{h,m}.
#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <ServiceManagement/ServiceManagement.h>
#import <libproc.h>
#import <mach/mach.h>
#import <signal.h>
#import <sys/mount.h>
#import <sys/sysctl.h>
#import <os/log.h>
#import "pure.h"

static NSString * const GBVersion = @"1.1.0";

// Tests and diagnostics can point Glancebar at an isolated fixture home without touching
// a real Codex/Claude installation. Normal app runs always fall back to the login home.
static NSString *GBHomeDirectory(void) {
    const char *override = getenv("GLANCEBAR_HOME");
    if (override && override[0]) {
        NSString *path = [NSString stringWithUTF8String:override];
        if (path.length) return path.stringByStandardizingPath;
    }
    return NSHomeDirectory();
}

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
    // APFS reports purgeable space in the "important usage" figure, which can exceed
    // total capacity; clamp so used/free/fraction stay self-consistent.
    if (important.longLongValue > 0) avail = important.longLongValue;
    // Network and transient volumes can briefly report -1 or a free-space figure larger
    // than their capacity. Clamp every source, not just the APFS "important" value.
    avail = MAX(0LL, MIN(avail, total.longLongValue));

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
        long percent = NumFor(d, @"CurrentCapacity");
        b.valid = percent >= 0 && percent <= 100;
        b.percent = b.valid ? (int)percent : 0;
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
    if (!p) return nil;   // executable path was not valid UTF-8
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
    NSError *launchError = nil;
    if (![t launchAndReturnError:&launchError]) return nil;

    // `top`, `ps`, and sqlite normally complete quickly. Never let a wedged child pin the
    // sampling queue or the serial AI reader forever; terminate at 8s and force-kill at 9s.
    __block BOOL timedOut = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!t.isRunning) return;
        timedOut = YES;
        [t terminate];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (t.isRunning) kill(t.processIdentifier, SIGKILL);
        });
    });
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    if (timedOut || t.terminationStatus != 0) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// Reads the live SleepDisabled system power setting (no admin needed — a plain IOKit read
// surfaced by `pmset -g`). YES = the Mac is currently kept awake with the lid closed.
static BOOL SleepDisabledNow(void) {
    return ParseSleepDisabled(RunTaskOutput(@"/usr/bin/pmset", @[@"-g"]) ?: @"").boolValue;
}

// Applies `pmset -a disablesleep <0|1>` through an osascript administrator prompt: macOS
// shows its own authentication dialog and runs pmset as root just this once — no background
// helper or LaunchDaemon is installed. Returns YES only if the change was applied (NO when
// the user cancels the prompt or authorization fails). The command and prompt are fixed
// literals with no interpolated user input, so there is no shell/AppleScript injection path.
static BOOL SetSleepDisabledViaAdmin(BOOL enable) {
    NSString *prompt = enable
        ? @"Glancebar needs administrator access to keep this Mac awake with the lid closed."
        : @"Glancebar needs administrator access to restore normal lid-close sleep.";
    NSString *script = [NSString stringWithFormat:
        @"do shell script \"/usr/bin/pmset -a disablesleep %d\" with prompt \"%@\" with administrator privileges",
        enable ? 1 : 0, prompt];
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    t.arguments = @[@"-e", script];
    t.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![t launchAndReturnError:NULL]) return NO;
    [t waitUntilExit];
    return t.terminationStatus == 0;
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
    return [NSString stringWithFormat:@"Memory pressure %@ · %@ available",
            MemoryPressureLevel(s), FmtBytes(s.memAvailable)];
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
@property (copy) NSString *limitRefreshError;
@property (copy) NSString *diagnostics;   // --dump only: why the gauge is or isn't shown
@property BOOL available, stale, limitStatusAvailable, limitStale, overageActive;
@property double remainingFraction;
@property long long todayTokens, weekTokens, todayMessages, todaySessions, todayToolCalls, weekSessions;
@property long long todayTokensAll, weekTokensAll;   // incl. cached context re-reads
@property (strong) NSDate *lastActivity;
@property (strong) NSDate *limitUpdatedAt;
@property (strong) NSDate *resetAt;   // the reset instant behind resetText, for countdowns
@property (copy) NSArray<NSDictionary *> *models;
@property (copy) NSArray<NSDictionary *> *limitWindows;   // all current limit windows (dual meter); bar still uses remainingFraction
@end
@implementation AIUsage @end

// How often an account limit may be re-fetched. Both endpoints rate-limit readily, so a
// cached figure younger than this is as current as a fresh fetch would have made it.
static const double kAccountPollInterval = 900;   // 15 minutes

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

static NSString *AsOfTextFromEpoch(double epoch) {
    if (epoch <= 0) return nil;
    NSString *when = ResetTextFromDate([NSDate dateWithTimeIntervalSince1970:epoch]);
    return when.length ? [@"as of " stringByAppendingString:when] : nil;
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
    BOOL replacedGauge = v >= 0;
    if (replacedGauge) {
        u.remainingFraction = MIN(1.0, MAX(0.0, v));
        u.limitStatusAvailable = YES;
    }

    NSString *reset = StatusStringForKeys(entry, @[@"resetText", @"reset", @"resets"]);
    NSString *resetAt = StatusStringForKeys(entry, @[@"resetAt", @"resetTime", @"resetsAt"]);
    NSDate *resetDate = DateFromStatusString(resetAt);
    if (resetDate) reset = ResetTextFromDate(resetDate);
    if (reset.length && (replacedGauge || (u.limitStatusAvailable && u.remainingFraction >= 0))) {
        u.resetText = reset;
        u.resetAt = resetDate;   // nil when the override gave free text — then the string is all we have
        replacedGauge = YES;
    }

    if (replacedGauge) {
        // A status-file entry is a true override, not a third opinion layered over the
        // provider. Clear provider-specific dual meters/overage so every surface agrees.
        u.limitWindows = @[];
        u.overageActive = NO;
        u.extraUsage = nil;
        u.limitStale = NO;
        u.limitUpdatedAt = nil;
    }

    NSString *reason = StatusStringForKeys(entry, @[@"status", @"detail", @"reason"]);
    u.statusSource = source;
    u.statusReason = reason.length ? reason : @"Limit status from local status file";
}

static AIUsage *ReadClaudeUsage(NSString *homeDirectory) {
    NSString *home = homeDirectory.length ? homeDirectory : GBHomeDirectory();
    NSString *path = [home stringByAppendingPathComponent:@".claude/stats-cache.json"];
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

    NSDictionary *latestTokensByModel = nil, *displayTokens = nil;
    NSString *latestDate = nil;
    for (NSDictionary *row in ([root[@"dailyModelTokens"] isKindOfClass:NSArray.class] ? root[@"dailyModelTokens"] : @[])) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *dateString = [row[@"date"] isKindOfClass:NSString.class] ? row[@"date"] : nil;
        NSDictionary *tokensByModel = [row[@"tokensByModel"] isKindOfClass:NSDictionary.class] ? row[@"tokensByModel"] : nil;
        NSDate *date = [DateOnlyFormatter() dateFromString:dateString ?: @""];
        if (!date || !tokensByModel) continue;
        if ([date compare:weekStart] != NSOrderedAscending && [date compare:now] != NSOrderedDescending)
            u.weekTokens += SumNumbersInDictionary(tokensByModel);
        if ([dateString isEqualToString:today]) {
            u.todayTokens = SumNumbersInDictionary(tokensByModel);
            if (u.todayTokens > 0) displayTokens = tokensByModel;
        }
        if (!latestDate || [dateString compare:latestDate] == NSOrderedDescending) {
            latestDate = dateString;
            latestTokensByModel = tokensByModel;
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

// Claude Code's credential item authorizes Apple's `apple-tool:` partition. Glancebar
// therefore asks the Apple-signed /usr/bin/security tool to read it; Keychain evaluates
// that tool's signature rather than Glancebar's, so the read is normally silent. This is
// an undocumented trust-boundary behavior, disclosed in-app before the opt-in is stored.
//
// This leans on undocumented partition behavior, so it is bounded and watchdogged: a hard
// deadline kills the child if `security` ever blocks (for example after an ACL change),
// so we degrade quietly instead of hanging on a dialog. The returned blob is
// a live OAuth token — callers must never log it.
static NSString *KeychainBlobViaSecurity(NSString *service) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/security"];
    t.arguments = @[@"find-generic-password", @"-w", @"-s", service, @"-a", NSUserName()];
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *pipe = [NSPipe pipe]; t.standardOutput = pipe;
    if (![t launchAndReturnError:nil]) return nil;

    // `security` normally returns instantly; if it ever wedges, terminate at 5s and
    // force-kill at 6s. Without the kill, a child that ignores SIGTERM leaves the read
    // below blocked forever and wedges the serial AI queue with it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!t.isRunning) return;
        [t terminate];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (t.isRunning) kill(t.processIdentifier, SIGKILL);
        });
    });

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];   // unblocks on exit/terminate
    [t waitUntilExit];
    if (t.terminationStatus != 0 || data.length == 0 || data.length > 64 * 1024) return nil;

    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// Opt-in only (the "Claude account for limit status" toggle): Claude Code keeps no
// quota state on disk — its /usage panel fetches from the API — so the only true gauge
// source is the same OAuth endpoint, authenticated with the token Claude Code already
// maintains in the Keychain. Returns nil when the toggle is off conceptually (callers
// gate), the item is missing, the read times out, or the value is not the expected JSON.
// Expiry is judged by the caller via ClaudeKeychainOutcome (never refresh the token
// ourselves — that could rotate the refresh token out from under Claude Code).
static NSDictionary *ClaudeAccessTokenFromKeychain(void) {
    NSString *blob = KeychainBlobViaSecurity(@"Claude Code-credentials");
    if (!blob.length) return nil;
    NSData *data = [blob dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *oauth = [json[@"claudeAiOauth"] isKindOfClass:NSDictionary.class] ? json[@"claudeAiOauth"] : nil;
    if (!oauth) return nil;
    NSString *token = [oauth[@"accessToken"] isKindOfClass:NSString.class] ? oauth[@"accessToken"] : nil;
    double expiresAt = [oauth[@"expiresAt"] doubleValue] / 1000.0;   // ms epoch
    return @{@"token": token ?: @"", @"expiresAt": @(expiresAt)};    // expiry judged by the caller
}

@interface GBAnthropicSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@end
@implementation GBAnthropicSessionDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
        willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                         newRequest:(NSURLRequest *)request
                  completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    // Authorization headers must never follow a provider-controlled redirect. A future
    // same-host HTTPS redirect is acceptable; every other destination is refused.
    NSURL *url = request.URL;
    BOOL sameTrustedHost = [url.scheme.lowercaseString isEqualToString:@"https"] &&
                           [url.host.lowercaseString isEqualToString:@"api.anthropic.com"];
    completionHandler(sameTrustedHost ? request : nil);
}
@end

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
    GBAnthropicSessionDelegate *delegate = [GBAnthropicSessionDelegate new];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:delegate delegateQueue:nil];

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

@interface GBCursorSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@end
@implementation GBCursorSessionDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
        willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                         newRequest:(NSURLRequest *)request
                  completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    NSURL *url = request.URL;
    BOOL sameTrustedHost = [url.scheme.lowercaseString isEqualToString:@"https"] &&
                           [url.host.lowercaseString isEqualToString:@"api2.cursor.sh"];
    completionHandler(sameTrustedHost ? request : nil);
}
@end

// Opt-in only: Cursor stores the signed-in session JWT in its VS Code state DB (not the
// Keychain). Returns the access token string, or nil when the DB/item is missing.
static NSString *CursorStateDBPath(NSString *homeDirectory) {
    NSString *home = homeDirectory.length ? homeDirectory : GBHomeDirectory();
    return [home stringByAppendingPathComponent:
        @"Library/Application Support/Cursor/User/globalStorage/state.vscdb"];
}

// Cursor only surfaces when its local app data is present — no empty "Cursor" card for
// machines that never installed it.
static BOOL CursorServicePresent(NSString *homeDirectory) {
    return [NSFileManager.defaultManager fileExistsAtPath:CursorStateDBPath(homeDirectory)];
}

static NSString *CursorAccessTokenFromStateDB(NSString *homeDirectory) {
    NSString *path = CursorStateDBPath(homeDirectory);
    NSString *sql = @"SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;";
    NSString *raw = RunSQLite(path, sql);
    if (!raw.length) return nil;
    NSString *token = [[raw componentsSeparatedByString:@"\n"].firstObject
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return token.length ? token : nil;
}

static NSDictionary *CursorFetchResult(NSData *data, NSHTTPURLResponse *http, NSError *err,
                                       NSString *fallbackMessage) {
    NSInteger statusCode = http.statusCode;
    NSTimeInterval retryAfter = [http.allHeaderFields[@"Retry-After"] doubleValue];
    if (!err && statusCode == 200 && data.length) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:NSDictionary.class]) return obj;
    }
    NSString *errorMessage = nil;
    if (data.length) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *dict = [obj isKindOfClass:NSDictionary.class] ? obj : nil;
        NSDictionary *error = [dict[@"error"] isKindOfClass:NSDictionary.class] ? dict[@"error"] : nil;
        NSString *message = [error[@"message"] isKindOfClass:NSString.class] ? error[@"message"] : nil;
        if (message.length) errorMessage = message;
        else if ([dict[@"message"] isKindOfClass:NSString.class]) errorMessage = dict[@"message"];
    }
    if (!errorMessage.length && err.localizedDescription.length) errorMessage = err.localizedDescription;
    if (!errorMessage.length) {
        errorMessage = statusCode > 0 ? [NSHTTPURLResponse localizedStringForStatusCode:statusCode]
                                      : fallbackMessage;
    }
    return @{@"_glancebarFetchError": @YES,
             @"statusCode": @(statusCode),
             @"rateLimited": @(statusCode == 429),
             @"retryAfter": @(retryAfter),
             @"message": errorMessage};
}

static NSDictionary *CursorHTTPJSON(NSString *token, NSString *method, NSString *urlString,
                                    NSDictionary *headers, NSData *body) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    req.HTTPMethod = method;
    req.timeoutInterval = 10;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    req.HTTPBody = body;
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    for (NSString *key in headers) [req setValue:headers[key] forHTTPHeaderField:key];

    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.URLCache = nil;
    cfg.HTTPCookieStorage = nil;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.HTTPShouldSetCookies = NO;
    GBCursorSessionDelegate *delegate = [GBCursorSessionDelegate new];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:delegate delegateQueue:nil];

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *json = nil;
    __block BOOL completed = NO;
    [[session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)resp : nil;
            json = CursorFetchResult(data, http, err, @"Cursor usage API request timed out");
            completed = YES;
            [session finishTasksAndInvalidate];
            dispatch_semaphore_signal(done);
        }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    if (!completed) [session invalidateAndCancel];
    if (!json) {
        return @{@"_glancebarFetchError": @YES,
                 @"statusCode": @0,
                 @"rateLimited": @NO,
                 @"retryAfter": @0,
                 @"message": @"Cursor usage API request timed out"};
    }
    return json;
}

// Prefer GetCurrentPeriodUsage (Pro/Team included spend). Fall back to legacy /auth/usage
// request buckets when the dashboard response has no usable planUsage window.
static NSDictionary *FetchCursorUsageJSON(NSString *token) {
    double now = NSDate.date.timeIntervalSince1970;
    NSData *emptyBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *period = CursorHTTPJSON(
        token, @"POST",
        @"https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
        @{@"Content-Type": @"application/json", @"Connect-Protocol-Version": @"1"},
        emptyBody);
    if (![period[@"_glancebarFetchError"] boolValue] && PickCursorLimitWindow(period, now))
        return period;

    NSDictionary *auth = CursorHTTPJSON(token, @"GET", @"https://api2.cursor.sh/auth/usage", nil, nil);
    if (![auth[@"_glancebarFetchError"] boolValue] && PickCursorLimitWindow(auth, now))
        return auth;
    // Keep a successful-but-empty period body over a transport error so diagnostics stay useful.
    if (![period[@"_glancebarFetchError"] boolValue]) return period;
    if (![auth[@"_glancebarFetchError"] boolValue]) return auth;
    return period;
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
// A single log line longer than this is abandoned rather than buffered. Distinct from the
// per-pass byte budget, which bounds work but must never abandon a line.
static const NSUInteger kAIMaxLineBytes = 4 * 1024 * 1024;

@interface AIReader : NSObject
@property BOOL useClaudeAccount;
@property BOOL allowClaudeAccountFetch;
@property BOOL allowClaudeTranscripts;
@property BOOL useCursorAccount;
@property BOOL allowCursorAccountFetch;
// A bounded pass intentionally leaves large histories unfinished. UI callers can
// immediately schedule another pass while needsImmediateRescan is true; diagnostics
// can drive catch-up without waiting for the normal 15-second refresh.
@property (readonly) BOOL needsImmediateRescan;
@property (readonly) BOOL totalsIncomplete;
@property (readonly) double catchUpProgress;
@property (readonly, copy) NSString *catchUpStatus;
- (instancetype)initWithHomeDirectory:(NSString *)homeDirectory;
- (instancetype)initWithHomeDirectory:(NSString *)homeDirectory
           applicationSupportDirectory:(NSString *)applicationSupportDirectory;
- (NSArray<AIUsage *> *)read;
- (NSArray<AIUsage *> *)readUntilCaughtUpWithTimeLimit:(NSTimeInterval)timeLimit;
// Drops the cached credential immediately. read/claudeUsage also clears it when the
// account is off, but no read runs while every AI surface is hidden, so withdrawing
// consent from the menu must not wait for one. Call on _aiQueue.
- (void)forgetClaudeAccountCredentials;
- (void)forgetCursorAccountCredentials;
// Writes out any state a catch-up pass left coalesced. Call on _aiQueue before quitting.
- (void)flushPersistentState;
@end

@implementation AIReader {
    NSString *_homeDirectory;
    NSString *_applicationSupportDirectory;
    NSString *_statePath;
    // Contributions live with their source file so truncation/replacement can remove
    // precisely the stale totals before the replacement is indexed.
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_codexFiles;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_claudeFiles;
    NSArray<NSDictionary *> *_codexInventory;
    NSArray<NSDictionary *> *_claudeInventory;
    double _codexInventoryValidUntil, _claudeInventoryValidUntil;
    NSMutableDictionary<NSString *, NSDictionary *> *_days;  // local "yyyy-MM-dd" -> @{@"t":, @"f":}
    NSDictionary *_limits;          // best known meters, merged across snapshots
    NSString *_limitsTs;
    // The newest snapshot verbatim. _limits is a deliberate blend of the best-known
    // meters, so asking IT whether Codex still speaks a shape we understand answers the
    // wrong question: one carried-forward window makes any blend look readable.
    NSDictionary *_limitsNewest;
    NSDate *_dbStamp;               // change detection for the sqlite extras
    NSString *_dbDay;
    long long _sessionsToday;
    NSArray<NSDictionary *> *_models;
    NSDate *_lastActivity;
    NSMutableDictionary<NSString *, NSDictionary *> *_claudeDays;
    NSDictionary *_claudeUsageJSON;             // last good OAuth usage response
    double _claudeNextFetch;                    // epoch; throttles the usage endpoint
    NSString *_claudeAccessToken;               // memory-only; never persisted by Glancebar
    double _claudeAccessTokenExpiresAt;
    double _claudeKeychainNextTry;
    NSString *_claudeAccountStatus;
    double _claudeLastSuccessAt;
    BOOL _claudeFetchedThisRun;                 // NO after disk restore until a live fetch succeeds
    BOOL _claudeUsageCacheAbandoned;            // YES after explicit forget; allows omitting on save
    NSDictionary *_cursorUsageJSON;             // last good Cursor usage response
    double _cursorNextFetch;
    NSString *_cursorAccessToken;               // memory-only; never persisted by Glancebar
    double _cursorStateNextTry;
    NSString *_cursorAccountStatus;
    double _cursorLastSuccessAt;
    BOOL _cursorFetchedThisRun;
    BOOL _cursorUsageCacheAbandoned;
    NSString *_lastFetchSkipReason;
    NSMutableDictionary<NSString *, NSString *> *_lastStatusReasons;
    NSUInteger _scanBytesRemaining;
    double _scanDeadline;
    unsigned long long _codexTotalBytes, _codexDoneBytes;
    unsigned long long _claudeTotalBytes, _claudeDoneBytes;
    BOOL _codexTotalsIncomplete, _claudeTotalsIncomplete;
    BOOL _codexBlocked, _claudeBlocked;
    BOOL _needsImmediateRescan;
    BOOL _stateDirty;
    // Set when the pending change REMOVES something (a consent withdrawal purging the
    // transcript index). Scan progress may wait for the next pass; a purge may not, because
    // there may be no next pass — hiding every AI surface stops read() entirely.
    BOOL _stateMustPersist;
    double _lastStateWrite;
    NSUInteger _stateWrites;   // diagnostic: how many times the state file was rewritten
}

- (instancetype)init {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                          NSUserDomainMask, YES).firstObject;
    NSString *fallback = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    NSString *support = [(base ?: fallback) stringByAppendingPathComponent:@"Glancebar"];
    return [self initWithHomeDirectory:NSHomeDirectory() applicationSupportDirectory:support];
}

- (instancetype)initWithHomeDirectory:(NSString *)homeDirectory {
    NSString *home = (homeDirectory.length ? homeDirectory : NSHomeDirectory()).stringByStandardizingPath;
    NSString *support = [home stringByAppendingPathComponent:@"Library/Application Support/Glancebar"];
    return [self initWithHomeDirectory:home applicationSupportDirectory:support];
}

- (instancetype)initWithHomeDirectory:(NSString *)homeDirectory
           applicationSupportDirectory:(NSString *)applicationSupportDirectory {
    if ((self = [super init])) {
        _homeDirectory = (homeDirectory.length ? homeDirectory : NSHomeDirectory()).stringByStandardizingPath;
        _applicationSupportDirectory = (applicationSupportDirectory.length
            ? applicationSupportDirectory
            : [_homeDirectory stringByAppendingPathComponent:@"Library/Application Support/Glancebar"])
            .stringByStandardizingPath;
        _statePath = [_applicationSupportDirectory stringByAppendingPathComponent:@"ai-reader-state-v2.json"];
        _codexFiles = [NSMutableDictionary dictionary];
        _claudeFiles = [NSMutableDictionary dictionary];
        _days = [NSMutableDictionary dictionary];
        _claudeDays = [NSMutableDictionary dictionary];
        _lastStatusReasons = [NSMutableDictionary dictionary];
        [self loadPersistentState];
    }
    return self;
}

- (void)loadPersistentState {
    NSData *data = [NSData dataWithContentsOfFile:_statePath options:0 error:nil];
    NSDictionary *root = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![root isKindOfClass:NSDictionary.class] || [root[@"version"] integerValue] != 2) return;
    NSString *timeZone = [root[@"timeZone"] isKindOfClass:NSString.class] ? root[@"timeZone"] : nil;
    if (timeZone.length && ![timeZone isEqualToString:NSTimeZone.localTimeZone.name]) return;
    NSDictionary *codex = [root[@"codexFiles"] isKindOfClass:NSDictionary.class] ? root[@"codexFiles"] : nil;
    NSDictionary *claude = [root[@"claudeFiles"] isKindOfClass:NSDictionary.class] ? root[@"claudeFiles"] : nil;
    for (NSString *key in codex) {
        NSDictionary *record = [codex[key] isKindOfClass:NSDictionary.class] ? codex[key] : nil;
        if (key.length && record) _codexFiles[key] = [record mutableCopy];
    }
    for (NSString *key in claude) {
        NSDictionary *record = [claude[key] isKindOfClass:NSDictionary.class] ? claude[key] : nil;
        if (key.length && record) _claudeFiles[key] = [record mutableCopy];
    }
    NSDictionary *limits = [root[@"codexLimits"] isKindOfClass:NSDictionary.class] ? root[@"codexLimits"] : nil;
    NSString *limitsTs = [root[@"codexLimitsTs"] isKindOfClass:NSString.class] ? root[@"codexLimitsTs"] : nil;
    if (limits && limitsTs.length) { _limits = limits; _limitsTs = limitsTs; }
    NSDictionary *claudeUsage = [root[@"claudeUsageJSON"] isKindOfClass:NSDictionary.class]
        ? root[@"claudeUsageJSON"] : nil;
    if (claudeUsage) {
        _claudeUsageJSON = claudeUsage;
        NSString *fetched = [root[@"claudeUsageFetchedAt"] isKindOfClass:NSString.class]
            ? root[@"claudeUsageFetchedAt"] : nil;
        NSDate *when = DateFromStatusString(fetched);
        if (when) _claudeLastSuccessAt = when.timeIntervalSince1970;
        _claudeFetchedThisRun = NO;
        _claudeUsageCacheAbandoned = NO;
    }
    NSDictionary *cursorUsage = [root[@"cursorUsageJSON"] isKindOfClass:NSDictionary.class]
        ? root[@"cursorUsageJSON"] : nil;
    if (cursorUsage) {
        _cursorUsageJSON = cursorUsage;
        NSString *fetched = [root[@"cursorUsageFetchedAt"] isKindOfClass:NSString.class]
            ? root[@"cursorUsageFetchedAt"] : nil;
        NSDate *when = DateFromStatusString(fetched);
        if (when) _cursorLastSuccessAt = when.timeIntervalSince1970;
        _cursorFetchedThisRun = NO;
        _cursorUsageCacheAbandoned = NO;
    }
}

// Indexing a large backlog drives read() in a tight catch-up loop, and each pass rewrote the
// whole (growing) state file. Coalesce those writes: during catch-up a lost write only costs
// a re-read of the last couple of seconds' bytes, since offsets and totals move together.
// The pass that finishes the backlog always writes, so a settled index is never stale.
static const double kAIStateWriteInterval = 2.0;

- (void)savePersistentStateIfNeeded {
    [self savePersistentStateForcingWrite:YES];
}

- (void)savePersistentStateCoalesced {
    [self savePersistentStateForcingWrite:NO];
}

- (void)savePersistentStateForcingWrite:(BOOL)force {
    if (!_stateDirty) return;
    if (_stateMustPersist) force = YES;
    double now = CFAbsoluteTimeGetCurrent();
    if (!force && _lastStateWrite > 0 && now - _lastStateWrite < kAIStateWriteInterval) return;
    NSDictionary *existingRoot = nil;
    {
        NSData *existingData = [NSData dataWithContentsOfFile:_statePath options:0 error:nil];
        id obj = existingData.length ? [NSJSONSerialization JSONObjectWithData:existingData options:0 error:nil] : nil;
        if ([obj isKindOfClass:NSDictionary.class]) existingRoot = obj;
    }
    NSMutableDictionary *root = [@{
        @"version": @2,
        @"timeZone": NSTimeZone.localTimeZone.name ?: @"",
        @"codexFiles": _codexFiles,
        @"claudeFiles": _claudeFiles
    } mutableCopy];
    if (_limits && _limitsTs.length) {
        root[@"codexLimits"] = _limits;
        root[@"codexLimitsTs"] = _limitsTs;
    }
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    if ([_claudeUsageJSON isKindOfClass:NSDictionary.class]) {
        root[@"claudeUsageJSON"] = _claudeUsageJSON;
        if (_claudeLastSuccessAt > 0)
            root[@"claudeUsageFetchedAt"] = [iso stringFromDate:
                [NSDate dateWithTimeIntervalSince1970:_claudeLastSuccessAt]];
    } else if (!_claudeUsageCacheAbandoned) {
        // Another process (or this one, before a successful fetch) may have the last-known
        // account snapshot on disk. Omitting the keys here would wipe it.
        if ([existingRoot[@"claudeUsageJSON"] isKindOfClass:NSDictionary.class])
            root[@"claudeUsageJSON"] = existingRoot[@"claudeUsageJSON"];
        if ([existingRoot[@"claudeUsageFetchedAt"] isKindOfClass:NSString.class])
            root[@"claudeUsageFetchedAt"] = existingRoot[@"claudeUsageFetchedAt"];
    }
    if ([_cursorUsageJSON isKindOfClass:NSDictionary.class]) {
        root[@"cursorUsageJSON"] = _cursorUsageJSON;
        if (_cursorLastSuccessAt > 0)
            root[@"cursorUsageFetchedAt"] = [iso stringFromDate:
                [NSDate dateWithTimeIntervalSince1970:_cursorLastSuccessAt]];
    } else if (!_cursorUsageCacheAbandoned) {
        if ([existingRoot[@"cursorUsageJSON"] isKindOfClass:NSDictionary.class])
            root[@"cursorUsageJSON"] = existingRoot[@"cursorUsageJSON"];
        if ([existingRoot[@"cursorUsageFetchedAt"] isKindOfClass:NSString.class])
            root[@"cursorUsageFetchedAt"] = existingRoot[@"cursorUsageFetchedAt"];
    }
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:&err];
    if (!data || err) { GBLog("AI state encode failed"); return; }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:_applicationSupportDirectory withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions: @0700} error:&err]) {
        GBLog("AI state directory unavailable");
        return;
    }
    if (![data writeToFile:_statePath options:NSDataWritingAtomic error:&err]) {
        GBLog("AI state write failed");
        return;
    }
    [fm setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:_statePath error:nil];
    _stateDirty = NO;
    _stateMustPersist = NO;
    _lastStateWrite = now;
    _stateWrites++;
}

- (void)flushPersistentState { [self savePersistentStateForcingWrite:YES]; }

- (NSUInteger)stateWriteCount { return _stateWrites; }

static NSString *FNVHashBytes(const void *rawBytes, NSUInteger length) {
    const unsigned char *bytes = rawBytes;
    uint64_t hash = UINT64_C(1469598103934665603);
    for (NSUInteger i = 0; i < length; i++) { hash ^= bytes[i]; hash *= UINT64_C(1099511628211); }
    return [NSString stringWithFormat:@"%016llx", (unsigned long long)hash];
}

static void StoreOffsetAnchor(NSMutableDictionary *record, NSData *data,
                              unsigned long long newOffset, NSUInteger consumed) {
    NSUInteger length = MIN((NSUInteger)64, consumed);
    if (!length) { [record removeObjectForKey:@"anchor"]; return; }
    NSRange range = NSMakeRange(consumed - length, length);
    record[@"anchor"] = FNVHashBytes((const char *)data.bytes + range.location, range.length);
    record[@"anchorOffset"] = @(newOffset);
    record[@"anchorLength"] = @(length);
}

// Reads complete appended lines within the caller's GLOBAL pass budget. A partial
// trailing line stays at the old offset and is retried only after the file grows.
//
// The two caps are not interchangeable. `lineCap` is a hard per-line ceiling: a line
// longer than it is abandoned so a pathological row cannot wedge the scan. `maxBytes` is
// the soft remaining pass budget, and a read it truncates says nothing about the line —
// the newline may sit one byte past it. Conflating them consumes an ordinary line
// whenever the budget happens to run out inside one, losing its tokens permanently.
- (NSData *)newLineDataAtPath:(NSString *)path
                       record:(NSMutableDictionary *)record
                     maxBytes:(NSUInteger)maxBytes
                      lineCap:(NSUInteger)lineCap
                    bytesRead:(NSUInteger *)bytesRead
                   readFailed:(BOOL *)readFailed {
    if (bytesRead) *bytesRead = 0;
    if (readFailed) *readFailed = NO;
    unsigned long long offset = [record[@"offset"] unsignedLongLongValue];
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) { if (readFailed) *readFailed = YES; return nil; }
    // These files belong to other tools and can be rotated/truncated mid-read; use the
    // error-returning APIs so an I/O failure skips the sample instead of raising.
    unsigned long long size = 0;
    NSError *err = nil;
    if (![fh seekToEndReturningOffset:&size error:&err]) {
        [fh closeAndReturnError:nil]; if (readFailed) *readFailed = YES; return nil;
    }
    unsigned long long priorSize = [record[@"size"] unsignedLongLongValue];
    if (offset > size || (priorSize > 0 && size < priorSize)) {
        // Truncation after inventory refresh: throw away this file's old contribution,
        // not merely its offset, or the replacement would be counted on top of it.
        NSNumber *dev = record[@"dev"], *ino = record[@"ino"];
        [record removeAllObjects];
        if (dev) record[@"dev"] = dev;
        if (ino) record[@"ino"] = ino;
        record[@"offset"] = @0;
        record[@"size"] = @(size);
        record[@"inventoryMismatch"] = @YES;
        _codexInventoryValidUntil = 0;
        _claudeInventoryValidUntil = 0;
        offset = 0;
        _stateDirty = YES;
    }
    if (!record[@"size"]) record[@"size"] = @(size);
    NSString *anchor = [record[@"anchor"] isKindOfClass:NSString.class] ? record[@"anchor"] : nil;
    NSUInteger anchorLength = [record[@"anchorLength"] unsignedIntegerValue];
    if (offset > 0 && anchor.length && anchorLength > 0 && anchorLength <= offset &&
        [record[@"anchorOffset"] unsignedLongLongValue] == offset) {
        if (![fh seekToOffset:offset - anchorLength error:&err]) {
            [fh closeAndReturnError:nil]; if (readFailed) *readFailed = YES; return nil;
        }
        NSData *anchorData = [fh readDataUpToLength:anchorLength error:&err];
        if (err || anchorData.length != anchorLength) {
            [fh closeAndReturnError:nil]; if (readFailed) *readFailed = YES; return nil;
        }
        if (![FNVHashBytes(anchorData.bytes, anchorData.length) isEqualToString:anchor]) {
            // Same inode and a regrown size can otherwise conceal truncate-and-rewrite.
            NSNumber *dev = record[@"dev"], *ino = record[@"ino"];
            [record removeAllObjects];
            if (dev) record[@"dev"] = dev;
            if (ino) record[@"ino"] = ino;
            record[@"offset"] = @0;
            record[@"size"] = @(size);
            offset = 0;
            _stateDirty = YES;
        }
    }
    if (offset >= size || maxBytes == 0) { [fh closeAndReturnError:nil]; return nil; }
    if (![fh seekToOffset:offset error:&err]) {
        [fh closeAndReturnError:nil]; if (readFailed) *readFailed = YES; return nil;
    }
    NSUInteger readCap = lineCap > 0 ? MIN(maxBytes, lineCap) : maxBytes;
    // True when the pass budget — not the line cap — is what ends this read short of EOF.
    BOOL budgetTruncated = lineCap > 0 && maxBytes < lineCap &&
                           (unsigned long long)maxBytes < size - offset;
    NSUInteger wanted = (NSUInteger)MIN((unsigned long long)readCap, size - offset);
    NSData *data = [fh readDataUpToLength:wanted error:&err];
    [fh closeAndReturnError:nil];
    if (bytesRead) *bytesRead = data.length;
    if (err) { if (readFailed) *readFailed = YES; return nil; }
    if (!data.length) return nil;
    const char *bytes = data.bytes;
    NSUInteger consume = 0;
    for (NSUInteger i = data.length; i > 0; i--) {
        if (bytes[i - 1] == '\n') { consume = i; break; }
    }
    BOOL reachedEOF = offset + data.length >= size;
    if (!consume && !reachedEOF && budgetTruncated) {
        // The budget, not the line cap, stopped this read, so the line is probably ordinary
        // and its newline sits just past the cut. Leave the offset where it is and re-read
        // the line whole on the next pass. The budget is still charged with the bytes read,
        // so the current pass still terminates.
        return nil;
    }
    if (!consume && !reachedEOF) {
        // Token-count lines are small. Skipping an overlong non-matching line bounds
        // memory and guarantees forward progress through pathological transcript rows.
        unsigned long long newOffset = offset + data.length;
        record[@"offset"] = @(newOffset);
        StoreOffsetAnchor(record, data, newOffset, data.length);
        [record removeObjectForKey:@"partialSize"];
        _stateDirty = YES;
        return nil;
    }
    if (!consume) {
        record[@"partialSize"] = @(size);
        _stateDirty = YES;
        return nil;
    }
    unsigned long long newOffset = offset + consume;
    record[@"offset"] = @(newOffset);
    StoreOffsetAnchor(record, data, newOffset, consume);
    if (reachedEOF && consume < data.length) record[@"partialSize"] = @(size);
    else [record removeObjectForKey:@"partialSize"];
    _stateDirty = YES;
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

static NSComparisonResult NewestCandidateFirst(NSDictionary *a, NSDictionary *b) {
    NSComparisonResult byTime = [b[@"mtime"] compare:a[@"mtime"]];
    if (byTime != NSOrderedSame) return byTime;
    return [b[@"size"] compare:a[@"size"]];
}

- (NSMutableDictionary *)recordForCandidate:(NSDictionary *)candidate
                                       files:(NSMutableDictionary<NSString *, NSMutableDictionary *> *)files {
    NSString *key = candidate[@"key"];
    NSMutableDictionary *record = files[key];
    NSNumber *oldDev = record[@"dev"], *oldIno = record[@"ino"];
    NSNumber *newDev = candidate[@"dev"], *newIno = candidate[@"ino"];
    BOOL identityChanged = record && oldDev && oldIno && newDev && newIno &&
        (![oldDev isEqual:newDev] || ![oldIno isEqual:newIno]);
    if (!record || identityChanged) {
        record = [NSMutableDictionary dictionaryWithObject:@0 forKey:@"offset"];
        files[key] = record;
        _stateDirty = YES;
    }
    for (NSString *field in @[@"dev", @"ino", @"size", @"mtime"]) {
        if ([field isEqualToString:@"size"] && [record[@"inventoryMismatch"] boolValue]) continue;
        id value = candidate[field];
        if (value && ![record[field] isEqual:value]) { record[field] = value; _stateDirty = YES; }
    }
    if (!record[@"offset"]) record[@"offset"] = @0;
    return record;
}

- (NSArray<NSDictionary *> *)refreshRecentInventory:(NSArray<NSDictionary *> *)inventory
                                               files:(NSMutableDictionary<NSString *, NSMutableDictionary *> *)files {
    NSMutableArray *updated = [inventory mutableCopy];
    NSUInteger count = MIN((NSUInteger)8, updated.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSMutableDictionary *candidate = [updated[i] mutableCopy];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:candidate[@"path"] error:nil];
        if (!attrs) {
            // A rollout may have moved to archived_sessions; force the next pass to
            // rebuild paths, while still avoiding another recursive walk in this pass.
            _codexInventoryValidUntil = 0;
            _claudeInventoryValidUntil = 0;
            continue;
        }
        NSDate *mtime = [attrs[NSFileModificationDate] isKindOfClass:NSDate.class]
            ? attrs[NSFileModificationDate] : nil;
        candidate[@"size"] = @([attrs[NSFileSize] unsignedLongLongValue]);
        candidate[@"mtime"] = @(mtime ? mtime.timeIntervalSince1970 : 0);
        if (attrs[NSFileSystemNumber]) candidate[@"dev"] = attrs[NSFileSystemNumber];
        if (attrs[NSFileSystemFileNumber]) candidate[@"ino"] = attrs[NSFileSystemFileNumber];
        NSString *key = candidate[@"key"];
        NSMutableDictionary *record = files[key];
        [record removeObjectForKey:@"inventoryMismatch"];
        if (record && [record[@"size"] unsignedLongLongValue] > [candidate[@"size"] unsignedLongLongValue]) {
            [files removeObjectForKey:key];
            _stateDirty = YES;
        }
        [self recordForCandidate:candidate files:files];
        updated[i] = candidate;
    }
    [updated sortUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return NewestCandidateFirst(a, b); }];
    return updated;
}

- (NSArray<NSDictionary *> *)codexInventory {
    double now = CFAbsoluteTimeGetCurrent();
    if (_codexInventory && now < _codexInventoryValidUntil) {
        _codexInventory = [self refreshRecentInventory:_codexInventory files:_codexFiles];
        return _codexInventory;
    }
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-8 * 24 * 3600];
    NSMutableDictionary<NSString *, NSDictionary *> *byKey = [NSMutableDictionary dictionary];
    for (NSString *dir in @[@".codex/sessions", @".codex/archived_sessions"]) {
        NSString *base = [_homeDirectory stringByAppendingPathComponent:dir];
        NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtPath:base];
        for (NSString *rel in en) {
            if (![rel.pathExtension isEqualToString:@"jsonl"]) continue;
            NSDictionary *attrs = en.fileAttributes;
            NSDate *mtime = [attrs[NSFileModificationDate] isKindOfClass:NSDate.class]
                ? attrs[NSFileModificationDate] : nil;
            if (mtime && [mtime compare:cutoff] == NSOrderedAscending) continue;
            NSString *key = rel.lastPathComponent;
            if (!key.length) continue;
            NSMutableDictionary *candidate = [@{
                @"key": key,
                @"path": [base stringByAppendingPathComponent:rel],
                @"size": @([attrs[NSFileSize] unsignedLongLongValue]),
                @"mtime": @(mtime ? mtime.timeIntervalSince1970 : 0)
            } mutableCopy];
            if (attrs[NSFileSystemNumber]) candidate[@"dev"] = attrs[NSFileSystemNumber];
            if (attrs[NSFileSystemFileNumber]) candidate[@"ino"] = attrs[NSFileSystemFileNumber];
            NSDictionary *prior = byKey[key];
            if (!prior || NewestCandidateFirst(candidate, prior) == NSOrderedAscending) byKey[key] = candidate;
        }
    }
    NSArray *inventory = [byKey.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return NewestCandidateFirst(a, b); }];
    NSMutableSet *seen = [NSMutableSet setWithArray:byKey.allKeys];
    for (NSDictionary *candidate in inventory) {
        NSString *key = candidate[@"key"];
        NSMutableDictionary *record = _codexFiles[key];
        [record removeObjectForKey:@"inventoryMismatch"];
        if (record && [record[@"size"] unsignedLongLongValue] > [candidate[@"size"] unsignedLongLongValue]) {
            [_codexFiles removeObjectForKey:key];
            _stateDirty = YES;
        }
        [self recordForCandidate:candidate files:_codexFiles];
    }
    for (NSString *key in _codexFiles.allKeys.copy) {
        if (![seen containsObject:key]) { [_codexFiles removeObjectForKey:key]; _stateDirty = YES; }
    }
    _codexInventory = inventory;
    _codexInventoryValidUntil = now + 30.0;   // normal ticks alternate full inventory / cheap active-file stats
    return inventory;
}

- (NSArray<NSDictionary *> *)claudeInventory {
    double now = CFAbsoluteTimeGetCurrent();
    if (_claudeInventory && now < _claudeInventoryValidUntil) {
        _claudeInventory = [self refreshRecentInventory:_claudeInventory files:_claudeFiles];
        return _claudeInventory;
    }
    NSString *base = [_homeDirectory stringByAppendingPathComponent:@".claude/projects"];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-8 * 24 * 3600];
    NSMutableArray<NSDictionary *> *inventory = [NSMutableArray array];
    NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtPath:base];
    for (NSString *rel in en) {
        if (![rel.pathExtension isEqualToString:@"jsonl"]) continue;
        NSDictionary *attrs = en.fileAttributes;
        NSDate *mtime = [attrs[NSFileModificationDate] isKindOfClass:NSDate.class]
            ? attrs[NSFileModificationDate] : nil;
        if (mtime && [mtime compare:cutoff] == NSOrderedAscending) continue;
        NSNumber *dev = attrs[NSFileSystemNumber], *ino = attrs[NSFileSystemFileNumber];
        const char *relBytes = rel.UTF8String;
        NSString *opaqueKey = dev && ino
            ? [NSString stringWithFormat:@"%llx-%llx", dev.unsignedLongLongValue, ino.unsignedLongLongValue]
            : [@"path-" stringByAppendingString:FNVHashBytes(relBytes ?: "", relBytes ? strlen(relBytes) : 0)];
        NSMutableDictionary *candidate = [@{
            // Persisted keys are opaque filesystem identities/hashes, never project paths.
            @"key": opaqueKey,
            @"path": [base stringByAppendingPathComponent:rel],
            @"size": @([attrs[NSFileSize] unsignedLongLongValue]),
            @"mtime": @(mtime ? mtime.timeIntervalSince1970 : 0)
        } mutableCopy];
        if (dev) candidate[@"dev"] = dev;
        if (ino) candidate[@"ino"] = ino;
        [inventory addObject:candidate];
    }
    [inventory sortUsingComparator:
        ^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return NewestCandidateFirst(a, b); }];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *candidate in inventory) {
        NSString *key = candidate[@"key"];
        [seen addObject:key];
        NSMutableDictionary *record = _claudeFiles[key];
        [record removeObjectForKey:@"inventoryMismatch"];
        if (record && [record[@"size"] unsignedLongLongValue] > [candidate[@"size"] unsignedLongLongValue]) {
            [_claudeFiles removeObjectForKey:key];
            _stateDirty = YES;
        }
        [self recordForCandidate:candidate files:_claudeFiles];
    }
    for (NSString *key in _claudeFiles.allKeys.copy) {
        if (![seen containsObject:key]) { [_claudeFiles removeObjectForKey:key]; _stateDirty = YES; }
    }
    _claudeInventory = inventory;
    _claudeInventoryValidUntil = now + 30.0;
    return inventory;
}

static void AddDays(NSMutableDictionary<NSString *, NSDictionary *> *sum, NSDictionary *days) {
    for (NSString *day in days) {
        NSDictionary *old = sum[day], *add = [days[day] isKindOfClass:NSDictionary.class] ? days[day] : nil;
        if (!add) continue;
        sum[day] = @{@"t": @([old[@"t"] longLongValue] + [add[@"t"] longLongValue]),
                     @"f": @([old[@"f"] longLongValue] + [add[@"f"] longLongValue])};
    }
}

- (void)rebuildCodexDerivedState {
    NSString *weekStart = WeekStartDayString();
    NSMutableDictionary *sum = [NSMutableDictionary dictionary];
    NSDictionary *bestLimits = nil, *newestLimits = nil;
    NSString *bestTs = nil;
    for (NSMutableDictionary *record in _codexFiles.allValues) {
        NSMutableDictionary *recordDays = [([record[@"days"] isKindOfClass:NSDictionary.class]
                                             ? record[@"days"] : @{}) mutableCopy];
        NSUInteger before = recordDays.count;
        PruneDays(recordDays, weekStart);
        if (recordDays.count != before) { record[@"days"] = recordDays; _stateDirty = YES; }
        AddDays(sum, recordDays);
        for (NSString *prefix in @[@"latest", @"peek"]) {
            NSString *tsKey = [prefix stringByAppendingString:@"Ts"];
            NSString *limitsKey = [prefix stringByAppendingString:@"Limits"];
            NSString *ts = [record[tsKey] isKindOfClass:NSString.class] ? record[tsKey] : nil;
            NSDictionary *limits = [record[limitsKey] isKindOfClass:NSDictionary.class] ? record[limitsKey] : nil;
            // Meter-wise, not snapshot-wise: once the weekly allowance is spent Codex
            // stops sending windows at all, so the newest snapshot alone knows least.
            if (limits && ts.length) {
                bestLimits = MergeCodexRateLimits(bestLimits, bestTs, limits, ts);
                if (!bestTs || [ts compare:bestTs] == NSOrderedDescending) {
                    bestTs = ts;
                    newestLimits = limits;   // kept verbatim, for the drift check
                }
            }
        }
    }
    _days = sum;
    _limits = bestLimits;
    _limitsTs = bestTs;
    _limitsNewest = newestLimits;
}

- (void)rebuildClaudeDerivedState {
    NSString *weekStart = WeekStartDayString();
    NSMutableDictionary *sum = [NSMutableDictionary dictionary];
    for (NSMutableDictionary *record in _claudeFiles.allValues) {
        NSMutableDictionary *recordDays = [([record[@"days"] isKindOfClass:NSDictionary.class]
                                             ? record[@"days"] : @{}) mutableCopy];
        NSUInteger before = recordDays.count;
        PruneDays(recordDays, weekStart);
        if (recordDays.count != before) { record[@"days"] = recordDays; _stateDirty = YES; }
        AddDays(sum, recordDays);
    }
    _claudeDays = sum;
}

- (void)consumeCodexData:(NSData *)chunk record:(NSMutableDictionary *)record {
    if (!chunk.length) return;
    NSMutableArray *events = [NSMutableArray array];
    ForEachMatchingLine(chunk, "\"token_count\"", ^(NSString *line) {
        NSDictionary *event = ParseTokenCountLine(line);
        if (event) [events addObject:event];
    });
    if (!events.count) return;
    NSDictionary *acc = AccumulateTokenEvents(record[@"days"], events, nil);
    record[@"days"] = acc[@"days"] ?: @{};
    NSString *ts = acc[@"latestTs"];
    if (ts.length) {
        NSString *keptTs = [record[@"latestTs"] isKindOfClass:NSString.class] ? record[@"latestTs"] : nil;
        NSDictionary *merged = MergeCodexRateLimits(record[@"latestLimits"], keptTs, acc[@"latestLimits"], ts);
        if (merged) record[@"latestLimits"] = merged;
        if (!keptTs || [ts compare:keptTs] == NSOrderedDescending) record[@"latestTs"] = ts;
    }
    _stateDirty = YES;
}

static NSString *HashedMessageID(NSString *messageID) {
    const unsigned char *bytes = (const unsigned char *)messageID.UTF8String;
    static const unsigned char empty[] = "";
    return FNVHashBytes(bytes ?: empty, bytes ? strlen((const char *)bytes) : 0);
}

- (void)consumeClaudeData:(NSData *)chunk record:(NSMutableDictionary *)record {
    if (!chunk.length) return;
    NSMutableArray *ids = [([record[@"ids"] isKindOfClass:NSArray.class] ? record[@"ids"] : @[]) mutableCopy];
    NSMutableSet *seen = [NSMutableSet setWithArray:ids];
    NSMutableArray *events = [NSMutableArray array];
    ForEachMatchingLine(chunk, "\"usage\"", ^(NSString *line) {
        NSDictionary *event = ParseClaudeUsageLine(line);
        if (!event) return;
        NSString *messageID = [event[@"id"] isKindOfClass:NSString.class] ? event[@"id"] : nil;
        if (messageID.length) {
            NSString *hashed = HashedMessageID(messageID);
            if ([seen containsObject:hashed]) return;
            [seen addObject:hashed];
            [ids addObject:hashed];
        }
        [events addObject:event];
    });
    // Keep hashes for the record's whole seven-day lifetime. A small rolling window can
    // double-count an older message amended much later; hashes are compact and contain
    // neither message content nor the original provider identifier.
    record[@"ids"] = ids;
    if (events.count) record[@"days"] = AccumulateTokenEvents(record[@"days"], events, nil)[@"days"] ?: @{};
    _stateDirty = YES;
}

- (NSData *)tailDataAtPath:(NSString *)path maxBytes:(NSUInteger)maxBytes
                 bytesRead:(NSUInteger *)bytesRead readFailed:(BOOL *)readFailed {
    if (bytesRead) *bytesRead = 0;
    if (readFailed) *readFailed = NO;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) { if (readFailed) *readFailed = YES; return nil; }
    NSError *err = nil;
    unsigned long long size = 0;
    if (![fh seekToEndReturningOffset:&size error:&err]) {
        [fh closeAndReturnError:nil]; if (readFailed) *readFailed = YES; return nil;
    }
    NSUInteger wanted = (NSUInteger)MIN((unsigned long long)maxBytes, size);
    if (![fh seekToOffset:size - wanted error:&err]) {
        [fh closeAndReturnError:nil]; if (readFailed) *readFailed = YES; return nil;
    }
    NSData *data = [fh readDataUpToLength:wanted error:&err];
    [fh closeAndReturnError:nil];
    if (bytesRead) *bytesRead = data.length;
    if (err && readFailed) *readFailed = YES;
    return err ? nil : data;
}

- (void)scanNewestCodexLimitFromInventory:(NSArray<NSDictionary *> *)inventory {
    NSUInteger attempts = 0;
    for (NSDictionary *candidate in inventory) {
        if (attempts >= 4 || _scanBytesRemaining == 0 || CFAbsoluteTimeGetCurrent() >= _scanDeadline) break;
        NSMutableDictionary *record = [self recordForCandidate:candidate files:_codexFiles];
        unsigned long long size = [candidate[@"size"] unsignedLongLongValue];
        if ([record[@"tailSize"] unsignedLongLongValue] == size) continue;
        attempts++;
        // Validate the persisted offset anchor before attaching a tail snapshot to the
        // record. If the same inode was rewritten, this clears its old totals first so
        // the freshly peeked limit is not then discarded by the historical read.
        BOOL validationFailed = NO;
        NSUInteger validationBytes = 0;
        [self newLineDataAtPath:candidate[@"path"] record:record maxBytes:0 lineCap:0
                     bytesRead:&validationBytes readFailed:&validationFailed];
        if (validationFailed) { _codexBlocked = YES; continue; }
        NSUInteger bytesRead = 0;
        BOOL failed = NO;
        NSUInteger wanted = MIN((NSUInteger)(512 * 1024), _scanBytesRemaining);
        NSData *tail = [self tailDataAtPath:candidate[@"path"] maxBytes:wanted
                                 bytesRead:&bytesRead readFailed:&failed];
        _scanBytesRemaining -= MIN(_scanBytesRemaining, bytesRead);
        if (failed) { _codexBlocked = YES; continue; }
        record[@"tailSize"] = @(size);
        _stateDirty = YES;
        __block NSDictionary *bestLimits = nil;
        __block NSString *bestTs = nil;
        ForEachMatchingLine(tail, "\"token_count\"", ^(NSString *line) {
            NSDictionary *event = ParseTokenCountLine(line);
            NSString *ts = [event[@"ts"] isKindOfClass:NSString.class] ? event[@"ts"] : nil;
            NSDictionary *limits = [event[@"limits"] isKindOfClass:NSDictionary.class] ? event[@"limits"] : nil;
            if (limits && ts.length) {
                bestLimits = MergeCodexRateLimits(bestLimits, bestTs, limits, ts);
                if (!bestTs || [ts compare:bestTs] == NSOrderedDescending) bestTs = ts;
            }
        });
        if (bestLimits) {
            record[@"peekLimits"] = bestLimits;
            record[@"peekTs"] = bestTs;
            break;   // newest modified file with a snapshot wins in normal Codex logs
        }
    }
}

- (void)progressForInventory:(NSArray<NSDictionary *> *)inventory
                       files:(NSDictionary<NSString *, NSMutableDictionary *> *)files
                       total:(unsigned long long *)total done:(unsigned long long *)done
                  incomplete:(BOOL *)incomplete {
    unsigned long long totalBytes = 0, doneBytes = 0;
    for (NSDictionary *candidate in inventory) {
        NSMutableDictionary *record = files[candidate[@"key"]];
        unsigned long long size = MAX([candidate[@"size"] unsignedLongLongValue],
                                      [record[@"size"] unsignedLongLongValue]);
        unsigned long long offset = MIN(size, [record[@"offset"] unsignedLongLongValue]);
        if (offset < size && [record[@"partialSize"] unsignedLongLongValue] == size) offset = size;
        totalBytes += size;
        doneBytes += offset;
    }
    if (total) *total = totalBytes;
    if (done) *done = doneBytes;
    if (incomplete) *incomplete = doneBytes < totalBytes;
}

// Rollout files keep their unique basename when they move to archived_sessions, so
// records survive the move. Inventory is cached during immediate catch-up passes;
// historical reads share one global byte/time budget and always start newest-first.
- (void)scanRollouts {
    NSArray *inventory = [self codexInventory];
    _codexBlocked = NO;
    [self scanNewestCodexLimitFromInventory:inventory];
    NSMutableSet *failedKeys = [NSMutableSet set];
    BOOL madeProgress = NO, stopped = NO;
    do {
        BOOL roundProgress = NO, foundWork = NO;
        for (NSDictionary *candidate in inventory) {
            if (_scanBytesRemaining == 0 || CFAbsoluteTimeGetCurrent() >= _scanDeadline) { stopped = YES; break; }
            NSString *key = candidate[@"key"];
            if ([failedKeys containsObject:key]) continue;
            NSMutableDictionary *record = [self recordForCandidate:candidate files:_codexFiles];
            unsigned long long size = MAX([candidate[@"size"] unsignedLongLongValue],
                                          [record[@"size"] unsignedLongLongValue]);
            unsigned long long offset = [record[@"offset"] unsignedLongLongValue];
            if (offset >= size || (offset < size && [record[@"partialSize"] unsignedLongLongValue] == size)) continue;
            foundWork = YES;
            NSUInteger bytesRead = 0;
            BOOL failed = NO;
            unsigned long long before = offset;
            NSData *chunk = [self newLineDataAtPath:candidate[@"path"] record:record
                                           maxBytes:_scanBytesRemaining lineCap:kAIMaxLineBytes
                                          bytesRead:&bytesRead readFailed:&failed];
            _scanBytesRemaining -= MIN(_scanBytesRemaining, bytesRead);
            if (failed) { [failedKeys addObject:key]; _codexBlocked = YES; continue; }
            [self consumeCodexData:chunk record:record];
            if ([record[@"offset"] unsignedLongLongValue] > before) roundProgress = madeProgress = YES;
        }
        if (stopped || !foundWork || !roundProgress) break;
    } while (_scanBytesRemaining > 0 && CFAbsoluteTimeGetCurrent() < _scanDeadline);
    [self rebuildCodexDerivedState];
    [self progressForInventory:inventory files:_codexFiles total:&_codexTotalBytes
                          done:&_codexDoneBytes incomplete:&_codexTotalsIncomplete];
    if (_codexTotalsIncomplete && (_scanBytesRemaining == 0 || CFAbsoluteTimeGetCurrent() >= _scanDeadline)) stopped = YES;
    _needsImmediateRescan |= _codexTotalsIncomplete && (madeProgress || stopped);
}

// Claude transcripts use the same bounded scanner. Only short hashes of recent message
// IDs are retained for amended-line de-duplication; no transcript content is persisted.
- (void)scanClaudeTranscripts {
    NSArray *inventory = [self claudeInventory];
    _claudeBlocked = NO;
    NSMutableSet *failedKeys = [NSMutableSet set];
    BOOL madeProgress = NO, stopped = NO;
    do {
        BOOL roundProgress = NO, foundWork = NO;
        for (NSDictionary *candidate in inventory) {
            if (_scanBytesRemaining == 0 || CFAbsoluteTimeGetCurrent() >= _scanDeadline) { stopped = YES; break; }
            NSString *key = candidate[@"key"];
            if ([failedKeys containsObject:key]) continue;
            NSMutableDictionary *record = [self recordForCandidate:candidate files:_claudeFiles];
            unsigned long long size = MAX([candidate[@"size"] unsignedLongLongValue],
                                          [record[@"size"] unsignedLongLongValue]);
            unsigned long long offset = [record[@"offset"] unsignedLongLongValue];
            if (offset >= size || (offset < size && [record[@"partialSize"] unsignedLongLongValue] == size)) continue;
            foundWork = YES;
            NSUInteger bytesRead = 0;
            BOOL failed = NO;
            unsigned long long before = offset;
            NSData *chunk = [self newLineDataAtPath:candidate[@"path"] record:record
                                           maxBytes:_scanBytesRemaining lineCap:kAIMaxLineBytes
                                          bytesRead:&bytesRead readFailed:&failed];
            _scanBytesRemaining -= MIN(_scanBytesRemaining, bytesRead);
            if (failed) { [failedKeys addObject:key]; _claudeBlocked = YES; continue; }
            [self consumeClaudeData:chunk record:record];
            if ([record[@"offset"] unsignedLongLongValue] > before) roundProgress = madeProgress = YES;
        }
        if (stopped || !foundWork || !roundProgress) break;
    } while (_scanBytesRemaining > 0 && CFAbsoluteTimeGetCurrent() < _scanDeadline);
    [self rebuildClaudeDerivedState];
    [self progressForInventory:inventory files:_claudeFiles total:&_claudeTotalBytes
                          done:&_claudeDoneBytes incomplete:&_claudeTotalsIncomplete];
    if (_claudeTotalsIncomplete && (_scanBytesRemaining == 0 || CFAbsoluteTimeGetCurrent() >= _scanDeadline)) stopped = YES;
    _needsImmediateRescan |= _claudeTotalsIncomplete && (madeProgress || stopped);
}

- (NSString *)claudeAccessTokenForNow:(double)now {
    if (_claudeAccessToken.length && (_claudeAccessTokenExpiresAt <= 0 || _claudeAccessTokenExpiresAt > now + 60))
        return _claudeAccessToken;
    if (now < _claudeKeychainNextTry) {
        if (!_claudeAccountStatus.length) _claudeAccountStatus = @"Keychain token unavailable; retrying later";
        return nil;
    }

    // Track latency so a future Keychain/ACL behavior change is diagnosable without ever
    // logging the credential or its contents.
    double readStart = CFAbsoluteTimeGetCurrent();
    NSDictionary *cred = ClaudeAccessTokenFromKeychain();
    double readMs = (CFAbsoluteTimeGetCurrent() - readStart) * 1000.0;
    NSDictionary *outcome = ClaudeKeychainOutcome(cred != nil, cred[@"token"],
                                                  [cred[@"expiresAt"] doubleValue], now);
    if (![outcome[@"ok"] boolValue]) {
        _claudeAccessToken = nil;
        _claudeAccessTokenExpiresAt = 0;
        _claudeKeychainNextTry = now + [outcome[@"retryDelay"] doubleValue];
        _claudeAccountStatus = outcome[@"status"];
        GBLog("keychain read: %{public}@ (%.0f ms)", outcome[@"status"], readMs);
        return nil;
    }

    _claudeAccessToken = outcome[@"token"];
    _claudeAccessTokenExpiresAt = [outcome[@"expiresAt"] doubleValue];
    _claudeKeychainNextTry = 0;
    GBLog("keychain read: ok (%.0f ms)", readMs);
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
    AIUsage *u = ReadClaudeUsage(_homeDirectory);   // stats-cache: sessions/messages/models (day-stale)
    if (self.allowClaudeTranscripts) {
        if (_claudeFiles.count) {
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
            if (_claudeTotalsIncomplete)
                u.statusText = _claudeBlocked && !_needsImmediateRescan
                    ? @"Transcript totals incomplete · some logs unreadable"
                    : [NSString stringWithFormat:@"Indexing transcripts %.0f%% · totals incomplete",
                       _claudeTotalBytes ? 100.0 * _claudeDoneBytes / _claudeTotalBytes : 0.0];
            else u.statusText = @"Tokens live from local transcripts";
            u.source = @"~/.claude transcripts + stats cache";
        }
    } else {
        // Withdrawn consent: the transcript index (message-ID hashes, per-day totals) must
        // leave the disk on this pass, not whenever a later one happens to run.
        if (_claudeFiles.count || _claudeDays.count) _stateDirty = _stateMustPersist = YES;
        [_claudeFiles removeAllObjects];
        [_claudeDays removeAllObjects];
        _claudeInventory = nil;
        _claudeInventoryValidUntil = 0;
        _claudeTotalBytes = _claudeDoneBytes = 0;
        _claudeTotalsIncomplete = _claudeBlocked = NO;
        if (u.statusText.length)
            u.statusText = [u.statusText stringByAppendingString:@" · transcript totals off"];
    }

    if (self.useClaudeAccount) {
        double now = NSDate.date.timeIntervalSince1970;
        if (ShouldFetchClaudeAccount(self.useClaudeAccount, self.allowClaudeAccountFetch,
                                     _claudeUsageJSON != nil, _claudeAccountStatus.length > 0,
                                     now, _claudeNextFetch)) {
            _claudeNextFetch = now + kAccountPollInterval;   // the endpoint rate-limits readily
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
                _claudeLastSuccessAt = now;
                _claudeFetchedThisRun = YES;
                _claudeUsageCacheAbandoned = NO;
                _stateDirty = _stateMustPersist = YES;
                [self savePersistentStateForcingWrite:YES];
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

        double nowForWindows = NSDate.date.timeIntervalSince1970;
        u.limitWindows = ClaudeLimitWindows(_claudeUsageJSON, nowForWindows);
        NSDictionary *pick = PickClaudeLimitWindow(_claudeUsageJSON, nowForWindows);
        BOOL usingStaleWindows = NO;
        if (!pick) {
            NSArray *staleWindows = ClaudeStaleLimitWindows(_claudeUsageJSON, nowForWindows);
            pick = PickClaudeStaleLimitWindow(_claudeUsageJSON, nowForWindows);
            if (pick) {
                u.limitWindows = staleWindows;
                usingStaleWindows = YES;
            }
        }
        NSString *fetchedAtISO = nil;
        if (_claudeLastSuccessAt > 0) {
            NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
            iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
            fetchedAtISO = [iso stringFromDate:[NSDate dateWithTimeIntervalSince1970:_claudeLastSuccessAt]];
        }
        if (pick) {
            u.limitStatusAvailable = YES;
            u.remainingFraction = [pick[@"remainingFraction"] doubleValue];
            u.limitUpdatedAt = _claudeLastSuccessAt > 0
                ? [NSDate dateWithTimeIntervalSince1970:_claudeLastSuccessAt] : nil;
            NSNumber *resets = pick[@"resetsAt"];
            if (resets) {
                u.resetAt = [NSDate dateWithTimeIntervalSince1970:resets.doubleValue];
                u.resetText = ResetTextFromDate(u.resetAt);
            }
            NSString *window = [NSString stringWithFormat:@"%@ window · your Claude account", pick[@"window"]];
            BOOL diskRestoredOnly = !_claudeFetchedThisRun && _claudeUsageJSON != nil;
            if (usingStaleWindows || diskRestoredOnly || _claudeAccountStatus.length)
                u.limitStale = YES;
            NSString *asOf = AsOfTextFromEpoch(_claudeLastSuccessAt);
            if (_claudeAccountStatus.length) {
                u.statusReason = asOf
                    ? [NSString stringWithFormat:@"Cached limit · %@ · %@ · %@",
                       _claudeAccountStatus, window, asOf]
                    : [NSString stringWithFormat:@"Cached limit · %@ · %@",
                       _claudeAccountStatus, window];
                u.statusSource = @"Cached Anthropic usage API response (opt-in)";
            } else if (usingStaleWindows) {
                u.statusReason = ClaudeLimitStatusReason(_claudeUsageJSON, fetchedAtISO, nowForWindows)
                    ?: window;
                u.statusSource = @"Cached Anthropic usage API response (opt-in)";
            } else if (diskRestoredOnly) {
                u.statusReason = asOf
                    ? [NSString stringWithFormat:@"Cached limit · %@ · %@", window, asOf]
                    : [@"Cached limit · " stringByAppendingString:window];
                u.statusSource = @"Cached Anthropic usage API response (opt-in)";
            } else {
                u.statusReason = window;
                u.statusSource = @"Anthropic usage API (opt-in)";
            }
        } else {
            NSString *fallback = ClaudeLimitStatusReason(_claudeUsageJSON, fetchedAtISO, nowForWindows)
                ?: (_claudeUsageJSON ? @"Account response has no current limit window"
                    : self.allowClaudeAccountFetch ? @"Claude account status unavailable"
                    : @"Claude account refresh paused until visible");
            u.statusReason = _claudeAccountStatus ?: (extraStatus[@"statusReason"] ?: fallback);
            if (self.allowClaudeAccountFetch) u.limitRefreshError = _claudeAccountStatus ?: fallback;
        }
        if ([extraStatus[@"overageActive"] boolValue]) {
            u.limitStatusAvailable = YES;
            u.remainingFraction = 0;
            u.overageActive = YES;
            u.resetText = @"Not provided";
            u.resetAt = nil;   // the window's own reset says nothing about paid overage
            // "You are being billed for overage" is the whole message here, so it stays
            // the whole reason. That the figure is cached rides on limitStale, and the
            // refresh error on limitRefreshError — both have their own place to appear.
            u.statusReason = extraStatus[@"statusReason"];
            if (_claudeAccountStatus.length) {
                u.limitStale = YES;
                u.statusSource = @"Cached Anthropic usage API response (opt-in)";
            } else {
                u.statusSource = @"Anthropic usage API (opt-in)";
            }
        }
        if (u.limitStatusAvailable && !u.limitUpdatedAt && _claudeLastSuccessAt > 0)
            u.limitUpdatedAt = [NSDate dateWithTimeIntervalSince1970:_claudeLastSuccessAt];
        if (_claudeAccountStatus.length) u.limitRefreshError = _claudeAccountStatus;
        u.diagnostics = [NSString stringWithFormat:@"usage JSON %@ · next fetch %@ · keychain %@",
            _claudeUsageJSON ? @"cached" : @"none",
            FmtEpochClock(_claudeNextFetch),
            _claudeKeychainNextTry > now
                ? [@"backoff until " stringByAppendingString:FmtEpochClock(_claudeKeychainNextTry)]
                : _claudeAccessToken.length ? @"token cached" : @"not read"];
    } else {
        [self forgetClaudeAccountCredentials];
        // The account can be unrequested because the user's toggle is off or because online
        // access was never granted (`--dump` without `--online`). Naming only the toggle
        // contradicts the accountEnabled=true this same run reports.
        u.diagnostics = @"account status not requested";
    }
    return u;
}

- (void)forgetClaudeAccountCredentials {
    BOOL hadCache = _claudeUsageJSON != nil || _claudeLastSuccessAt > 0 || !_claudeUsageCacheAbandoned;
    _claudeAccessToken = nil;
    _claudeAccessTokenExpiresAt = 0;
    _claudeUsageJSON = nil;
    _claudeAccountStatus = nil;
    _claudeLastSuccessAt = 0;
    _claudeNextFetch = 0;
    _claudeFetchedThisRun = NO;
    _claudeUsageCacheAbandoned = YES;
    if (hadCache) {
        _stateDirty = _stateMustPersist = YES;
        [self savePersistentStateForcingWrite:YES];
    }
}

- (NSString *)cursorAccessTokenForNow:(double)now {
    if (_cursorAccessToken.length) return _cursorAccessToken;
    if (now < _cursorStateNextTry) {
        if (!_cursorAccountStatus.length) _cursorAccountStatus = @"Cursor session unavailable; retrying later";
        return nil;
    }
    double readStart = CFAbsoluteTimeGetCurrent();
    NSString *token = CursorAccessTokenFromStateDB(_homeDirectory);
    double readMs = (CFAbsoluteTimeGetCurrent() - readStart) * 1000.0;
    if (!token.length) {
        _cursorAccessToken = nil;
        _cursorStateNextTry = now + 3600;   // missing session: don't hammer sqlite every tick
        _cursorAccountStatus = @"Cursor session unavailable; retrying later";
        GBLog("cursor state read: missing (%.0f ms)", readMs);
        return nil;
    }
    _cursorAccessToken = token;
    _cursorStateNextTry = 0;
    GBLog("cursor state read: ok (%.0f ms)", readMs);
    return _cursorAccessToken;
}

- (void)rememberCursorFetchError:(NSDictionary *)fetch now:(double)now {
    BOOL rateLimited = [fetch[@"rateLimited"] boolValue];
    double retry = [fetch[@"retryAfter"] doubleValue];
    NSString *message = [fetch[@"message"] isKindOfClass:NSString.class] ? fetch[@"message"] : nil;
    if (ShouldDropCachedTokenForStatus([fetch[@"statusCode"] integerValue])) {
        _cursorAccessToken = nil;   // revoked/expired; re-read state.vscdb next attempt
    }
    if (rateLimited) {
        _cursorNextFetch = now + RateLimitRetryDelay(retry);
        _cursorAccountStatus = @"Usage API rate-limited; retrying later";
    } else {
        _cursorAccountStatus = message.length ? [@"Usage API: " stringByAppendingString:message]
                                              : @"Usage API unavailable";
    }
}

- (AIUsage *)cursorUsage {
    AIUsage *u = [AIUsage new];
    u.name = @"Cursor";
    u.source = @"Cursor local session + api2.cursor.sh";
    u.remainingFraction = -1;
    u.resetText = @"Not exposed locally";
    u.statusReason = @"Cursor account access is off";
    u.models = @[];
    u.available = NO;

    if (self.useCursorAccount) {
        double now = NSDate.date.timeIntervalSince1970;
        // Same visibility/throttle gate as Claude: reuse the pure decision.
        if (ShouldFetchClaudeAccount(self.useCursorAccount, self.allowCursorAccountFetch,
                                     _cursorUsageJSON != nil, _cursorAccountStatus.length > 0,
                                     now, _cursorNextFetch)) {
            _cursorNextFetch = now + kAccountPollInterval;
            _lastFetchSkipReason = nil;
            NSString *token = [self cursorAccessTokenForNow:now];
            NSDictionary *fetch = token ? FetchCursorUsageJSON(token) : nil;
            if ([fetch[@"_glancebarFetchError"] boolValue]) {
                [self rememberCursorFetchError:fetch now:now];
                GBLog("cursor fetch: failed http=%ld rateLimited=%d",
                      (long)[fetch[@"statusCode"] integerValue], [fetch[@"rateLimited"] boolValue]);
            } else if (fetch && !fetch[@"error"]) {
                _cursorUsageJSON = fetch;
                _cursorAccountStatus = nil;
                _cursorLastSuccessAt = now;
                _cursorFetchedThisRun = YES;
                _cursorUsageCacheAbandoned = NO;
                _stateDirty = _stateMustPersist = YES;
                [self savePersistentStateForcingWrite:YES];
                GBLog("cursor fetch: ok");
            } else if (token.length) {
                _cursorAccountStatus = @"Usage API unavailable";
                GBLog("cursor fetch: unusable response");
            }
        } else {
            NSString *skip = !self.allowCursorAccountFetch ? @"cursor-hidden" : @"cursor-throttled";
            if (![skip isEqualToString:_lastFetchSkipReason]) {
                GBLog("cursor fetch: skipped (%{public}@)", skip);
                _lastFetchSkipReason = skip;
            }
        }

        u.limitWindows = CursorLimitWindows(_cursorUsageJSON, now);
        NSDictionary *pick = PickCursorLimitWindow(_cursorUsageJSON, now);
        BOOL usingStaleWindows = NO;
        if (!pick) {
            NSArray *staleWindows = CursorStaleLimitWindows(_cursorUsageJSON, now);
            pick = PickCursorStaleLimitWindow(_cursorUsageJSON, now);
            if (pick) {
                u.limitWindows = staleWindows;
                usingStaleWindows = YES;
            }
        }
        NSString *fetchedAtISO = nil;
        if (_cursorLastSuccessAt > 0) {
            NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
            iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
            fetchedAtISO = [iso stringFromDate:[NSDate dateWithTimeIntervalSince1970:_cursorLastSuccessAt]];
        }
        if (pick) {
            u.available = YES;
            u.limitStatusAvailable = YES;
            u.remainingFraction = [pick[@"remainingFraction"] doubleValue];
            u.limitUpdatedAt = _cursorLastSuccessAt > 0
                ? [NSDate dateWithTimeIntervalSince1970:_cursorLastSuccessAt] : nil;
            NSNumber *resets = pick[@"resetsAt"];
            if (resets) {
                u.resetAt = [NSDate dateWithTimeIntervalSince1970:resets.doubleValue];
                u.resetText = ResetTextFromDate(u.resetAt);
            }
            NSString *window = [NSString stringWithFormat:@"%@ · your Cursor account", pick[@"window"]];
            BOOL diskRestoredOnly = !_cursorFetchedThisRun && _cursorUsageJSON != nil;
            if (usingStaleWindows || diskRestoredOnly || _cursorAccountStatus.length)
                u.limitStale = YES;
            NSString *asOf = AsOfTextFromEpoch(_cursorLastSuccessAt);
            if (_cursorAccountStatus.length) {
                u.statusReason = asOf
                    ? [NSString stringWithFormat:@"Cached limit · %@ · %@ · %@",
                       _cursorAccountStatus, window, asOf]
                    : [NSString stringWithFormat:@"Cached limit · %@ · %@",
                       _cursorAccountStatus, window];
                u.statusSource = @"Cached Cursor usage API response (opt-in)";
            } else if (usingStaleWindows) {
                u.statusReason = CursorLimitStatusReason(_cursorUsageJSON, fetchedAtISO, now)
                    ?: window;
                u.statusSource = @"Cached Cursor usage API response (opt-in)";
            } else if (diskRestoredOnly) {
                u.statusReason = asOf
                    ? [NSString stringWithFormat:@"Cached limit · %@ · %@", window, asOf]
                    : [@"Cached limit · " stringByAppendingString:window];
                u.statusSource = @"Cached Cursor usage API response (opt-in)";
            } else {
                u.statusReason = window;
                u.statusSource = @"Cursor usage API (opt-in)";
            }
            u.statusText = @"Limit status from Cursor account";
        } else {
            NSString *fallback = CursorLimitStatusReason(_cursorUsageJSON, fetchedAtISO, now)
                ?: (_cursorUsageJSON ? @"Account response has no current limit window"
                    : self.allowCursorAccountFetch ? @"Cursor account status unavailable"
                    : @"Cursor account refresh paused until visible");
            u.statusReason = _cursorAccountStatus ?: fallback;
            if (self.allowCursorAccountFetch) u.limitRefreshError = _cursorAccountStatus ?: fallback;
        }
        if (u.limitStatusAvailable && !u.limitUpdatedAt && _cursorLastSuccessAt > 0)
            u.limitUpdatedAt = [NSDate dateWithTimeIntervalSince1970:_cursorLastSuccessAt];
        if (_cursorAccountStatus.length) u.limitRefreshError = _cursorAccountStatus;
        u.diagnostics = [NSString stringWithFormat:@"usage JSON %@ · next fetch %@ · session %@",
            _cursorUsageJSON ? @"cached" : @"none",
            FmtEpochClock(_cursorNextFetch),
            _cursorStateNextTry > now
                ? [@"backoff until " stringByAppendingString:FmtEpochClock(_cursorStateNextTry)]
                : _cursorAccessToken.length ? @"token cached" : @"not read"];
    } else {
        [self forgetCursorAccountCredentials];
        u.diagnostics = @"account status not requested";
    }
    return u;
}

- (void)forgetCursorAccountCredentials {
    BOOL hadCache = _cursorUsageJSON != nil || _cursorLastSuccessAt > 0 || !_cursorUsageCacheAbandoned;
    _cursorAccessToken = nil;
    _cursorUsageJSON = nil;
    _cursorAccountStatus = nil;
    _cursorLastSuccessAt = 0;
    _cursorNextFetch = 0;
    _cursorStateNextTry = 0;
    _cursorFetchedThisRun = NO;
    _cursorUsageCacheAbandoned = YES;
    if (hadCache) {
        _stateDirty = _stateMustPersist = YES;
        [self savePersistentStateForcingWrite:YES];
    }
}

// Session counts, per-model split, and last activity still come from the sqlite thread
// store (the rollouts don't carry the model); re-queried only when the db changes.
- (NSString *)codexStatePath {
    NSString *dir = [_homeDirectory stringByAppendingPathComponent:@".codex"];
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    NSString *best = nil;
    long bestVersion = -1;
    for (NSString *name in names) {
        if (![name hasPrefix:@"state_"] || ![name hasSuffix:@".sqlite"] || name.length <= 13) continue;
        long version = [name substringWithRange:NSMakeRange(6, name.length - 13)].integerValue;
        if (version > bestVersion) { bestVersion = version; best = name; }
    }
    return best ? [dir stringByAppendingPathComponent:best] : nil;
}

- (void)refreshDBExtras {
    NSString *path = [self codexStatePath];
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
    [self refreshDBExtras];

    AIUsage *u = [AIUsage new];
    u.name = @"Codex";
    u.source = @"~/.codex session logs";
    u.remainingFraction = -1;
    u.resetText = @"Not exposed locally";
    u.models = _models ?: @[];
    u.available = _codexFiles.count > 0;
    if (!u.available) {
        u.statusText = @"Local state not found";
        u.statusReason = @"No Codex session logs under ~/.codex";
        return u;
    }
    if (_codexTotalsIncomplete)
        u.statusText = _codexBlocked && !_needsImmediateRescan
            ? @"Totals incomplete · some session logs unreadable"
            : [NSString stringWithFormat:@"Indexing %.0f%% · totals incomplete",
               _codexTotalBytes ? 100.0 * _codexDoneBytes / _codexTotalBytes : 0.0];
    else u.statusText = @"Per-turn session logs";
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

    // Read drift from the newest snapshot as it arrived, not from the merged view.
    NSString *drift = CodexSchemaDriftReason(_limitsNewest);
    u.limitWindows = CodexLimitWindows(_limits, now);
    NSDictionary *pick = PickLimitWindow(_limits, now);
    if (pick) {
        u.limitStatusAvailable = YES;
        u.remainingFraction = [pick[@"remainingFraction"] doubleValue];
        NSNumber *resets = pick[@"resetsAt"];
        if (resets) {
            u.resetAt = [NSDate dateWithTimeIntervalSince1970:resets.doubleValue];
            u.resetText = ResetTextFromDate(u.resetAt);
        }
        NSString *plan = [pick[@"plan"] isKindOfClass:NSString.class] ? pick[@"plan"] : nil;
        u.statusReason = plan.length
            ? [NSString stringWithFormat:@"%@ window · %@ plan", pick[@"window"], plan]
            : [NSString stringWithFormat:@"%@ window", pick[@"window"]];
        u.statusSource = @"~/.codex session logs";
        // A window carried forward from an earlier snapshot is as old as its own
        // observation, not as old as the latest snapshot — and that makes it stale,
        // which is exactly what the row's "cached" marker exists to say.
        NSString *observed = [pick[@"observedAt"] isKindOfClass:NSString.class] ? pick[@"observedAt"] : nil;
        u.limitUpdatedAt = DateFromStatusString(observed ?: _limitsTs);
        if (observed.length && _limitsTs.length && [observed compare:_limitsTs] == NSOrderedAscending)
            u.limitStale = YES;
    }
    // With no gauge left, "the payload changed shape" beats "the windows have reset":
    // both are true, but only one tells the user why no new number is coming.
    else u.statusReason = drift ?: CodexLimitStatusReason(_limits, _limitsTs, now);

    // Context, never the gauge: a zero credit balance is normal while the plan window
    // still has room. See CodexCreditsStatus.
    NSDictionary *credits = CodexCreditsStatus(_limits);
    if (credits[@"description"]) u.extraUsage = credits[@"description"];
    // Say it even while a carried-forward window still reads, or the cause hides behind
    // up to a week of apparently-healthy rows. limitRefreshError is exactly "why the
    // figure above is the last-known one", and Codex never sets it otherwise.
    // (--strict consults only Claude/Cursor, so this cannot change an exit code.)
    if (drift.length) u.limitRefreshError = drift;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"limits snapshot %@",
                      _limitsTs.length ? _limitsTs : @"never seen"]];
    if (drift.length) [parts addObject:drift];
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
    if (_codexTotalsIncomplete) [parts addObject:[NSString stringWithFormat:@"indexing %.1f%%",
        _codexTotalBytes ? 100.0 * _codexDoneBytes / _codexTotalBytes : 0.0]];
    u.diagnostics = [parts componentsJoinedByString:@" · "];
    return u;
}

- (NSArray<AIUsage *> *)read {
    // One budget covers Codex and the opt-in Claude transcript reader together. Codex
    // goes first so the tail snapshot makes the live limit gauge available even while
    // historical totals are still catching up.
    _scanBytesRemaining = 16 * 1024 * 1024;
    _scanDeadline = CFAbsoluteTimeGetCurrent() + 0.35;
    _needsImmediateRescan = NO;
    [self scanRollouts];
    if (self.allowClaudeTranscripts) [self scanClaudeTranscripts];
    NSMutableArray<AIUsage *> *usage = [NSMutableArray arrayWithObjects:
                                        [self claudeUsage], [self codexUsage], nil];
    // Cursor is a local product, not a universal CLI — only surface it when Cursor's
    // state DB exists on this Mac (same path the opt-in session read uses).
    if (CursorServicePresent(_homeDirectory)) [usage addObject:[self cursorUsage]];
    else if (self.useCursorAccount) [self forgetCursorAccountCredentials];
    NSString *statusPath = [_homeDirectory stringByAppendingPathComponent:@".glancebar/ai-status.json"];
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
    // Mid-catch-up another pass follows immediately, so coalesce. The pass that lands the
    // backlog (and every steady-state pass) flushes.
    if (_needsImmediateRescan) [self savePersistentStateCoalesced];
    else [self savePersistentStateIfNeeded];
    return usage;
}

- (BOOL)needsImmediateRescan { return _needsImmediateRescan; }
- (BOOL)totalsIncomplete { return _codexTotalsIncomplete ||
    (self.allowClaudeTranscripts && _claudeTotalsIncomplete); }

- (double)catchUpProgress {
    unsigned long long total = _codexTotalBytes;
    unsigned long long done = _codexDoneBytes;
    if (self.allowClaudeTranscripts) { total += _claudeTotalBytes; done += _claudeDoneBytes; }
    return total ? MIN(1.0, (double)done / (double)total) : 1.0;
}

- (NSString *)catchUpStatus {
    if (!self.totalsIncomplete) return @"Local AI totals current";
    if (!_needsImmediateRescan && (_codexBlocked || (self.allowClaudeTranscripts && _claudeBlocked)))
        return @"AI totals incomplete · some logs unreadable";
    return [NSString stringWithFormat:@"Indexing %.0f%% · totals incomplete", self.catchUpProgress * 100.0];
}

- (NSArray<AIUsage *> *)readUntilCaughtUpWithTimeLimit:(NSTimeInterval)timeLimit {
    NSArray<AIUsage *> *usage = nil;
    double deadline = CFAbsoluteTimeGetCurrent() + MAX(0.0, timeLimit);
    do {
        usage = [self read];
    } while (self.needsImmediateRescan && CFAbsoluteTimeGetCurrent() < deadline);
    return usage ?: @[];
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
@property (nonatomic) double fraction;
@property (nonatomic, strong) NSColor *color;
@property (nonatomic, copy) NSString *metricLabel;
@end
@implementation Gauge
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self setAccessibilityElement:YES];
        [self setAccessibilityRole:NSAccessibilityProgressIndicatorRole];
        [self setAccessibilityMinValue:@0.0];
        [self setAccessibilityMaxValue:@1.0];
        [self setAccessibilityLabel:@"Progress"];
    }
    return self;
}
- (void)setFraction:(double)fraction {
    _fraction = MIN(1.0, MAX(0.0, fraction));
    [self setAccessibilityValue:@(_fraction)];
    self.needsDisplay = YES;
}
- (void)setColor:(NSColor *)color { _color = color; self.needsDisplay = YES; }
- (void)setMetricLabel:(NSString *)metricLabel {
    _metricLabel = [metricLabel copy];
    [self setAccessibilityLabel:_metricLabel.length ? _metricLabel : @"Progress"];
    [self setAccessibilityIdentifier:_metricLabel.length
        ? [@"gauge." stringByAppendingString:_metricLabel] : @"gauge.progress"];
}
- (void)drawRect:(NSRect)d {
    NSRect r = self.bounds; CGFloat rad = r.size.height/2;
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad] fill];
    NSRect f = r; f.size.width = MAX(r.size.height, r.size.width*self.fraction);
    [(self.color ?: NSColor.controlAccentColor) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:f xRadius:rad yRadius:rad] fill];
}
@end

@interface FlippedView : NSView
// The section heading the next row belongs under, and the per-identifier occurrence counts
// used to disambiguate genuine duplicates. Together these give a row a stable identity that
// does not move when another row is inserted above it.
@property (nonatomic, copy) NSString *accessibilitySection;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *accessibilityIdentifierCounts;
@end
@implementation FlippedView - (BOOL)isFlipped { return YES; } @end

// Opaque, appearance-adaptive backing for the popover. The default NSPopover material is
// translucent (behind-window vibrancy), so a dark or saturated window behind the menu bar
// bleeds through and washes out the fixed semantic text colors toward the bottom of the
// panel. Fill an opaque background so contrast holds regardless of the backdrop. Drawn in
// drawRect: — not a CALayer background color — so windowBackgroundColor re-resolves under
// the current Light/Dark appearance on every redraw instead of being frozen at assignment.
//
// AppKit does not clip drawRect: to a view's bounds unless the view is layer-backed
// (clipsToBounds itself is macOS 14+, and the deployment target is 13.0). As the full-size
// root that is harmless, but any SHORT instance of this view must set wantsLayer, or its
// fill will paint over whatever sits above it. See the popover footer.
@interface PopoverRootView : FlippedView @end
@implementation PopoverRootView
- (void)drawRect:(NSRect)dirty {
    [NSColor.windowBackgroundColor set];
    NSRectFill(NSIntersectionRect(dirty, self.bounds));
}
// A dynamic system color only re-resolves when something redraws. Nothing else marks this
// view dirty on a live Light/Dark switch.
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
@end

// NSAccessibilityHeadingRole is API_AVAILABLE(macos(26.0)), so an older SDK cannot even name
// it and the file will not compile there. Guard on the SDK as well as the runtime version,
// and speak the heading through a label wherever the role is unavailable.
static void ApplyHeadingAccessibility(NSTextField *heading, NSString *title) {
#if defined(MAC_OS_VERSION_26_0) && MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_VERSION_26_0
    if (@available(macOS 26.0, *)) {
        heading.accessibilityRole = NSAccessibilityHeadingRole;
        return;
    }
#endif
    heading.accessibilityLabel = [NSString stringWithFormat:@"%@ section heading", title];
}

// Returns `base`, or base#2, base#3 … for repeat uses within one detail root. `namespace`
// keeps the section counter from colliding with the identifier counter.
static NSString *DisambiguatedDetailKey(FlippedView *root, NSString *ns, NSString *base) {
    if (!root) return base;
    if (!root.accessibilityIdentifierCounts) root.accessibilityIdentifierCounts = [NSMutableDictionary dictionary];
    NSString *counterKey = [NSString stringWithFormat:@"%@|%@", ns, base];
    NSInteger n = root.accessibilityIdentifierCounts[counterKey].integerValue + 1;
    root.accessibilityIdentifierCounts[counterKey] = @(n);
    return n > 1 ? [base stringByAppendingFormat:@"#%ld", (long)n] : base;
}

// An accessibility identifier must name the field, not its position. These were built from a
// running build-order counter, so inserting one row renamed every row below it and focus
// restoration — which matches identifiers exactly — landed on the wrong field. Key off the
// enclosing section instead, whose key the caller supplies as a stable semantic path
// ("local-history.codex.models"). Nothing here may depend on how many siblings were built
// first, or a conditional section appearing elsewhere would rename these rows again.
static NSString *DetailIdentifier(NSView *root, NSString *kind, NSString *label) {
    FlippedView *detailRoot = [root isKindOfClass:FlippedView.class] ? (FlippedView *)root : nil;
    NSString *scope = root.accessibilityIdentifier ?: @"details";
    NSString *section = detailRoot.accessibilitySection;
    NSString *base = section.length
        ? [NSString stringWithFormat:@"%@.%@.%@.%@", scope, kind, section, label.lowercaseString]
        : [NSString stringWithFormat:@"%@.%@.%@", scope, kind, label.lowercaseString];
    return DisambiguatedDetailKey(detailRoot, @"id", base);
}

static NSView *ViewWithAccessibilityIdentifier(NSView *root, NSString *identifier) {
    if (!root || !identifier.length) return nil;
    if ([root.accessibilityIdentifier isEqualToString:identifier]) return root;
    for (NSView *child in root.subviews) {
        NSView *match = ViewWithAccessibilityIdentifier(child, identifier);
        if (match) return match;
    }
    return nil;
}

static NSView *ViewOwningAccessibilityElement(NSView *root, id element) {
    if (!root || !element) return nil;
    if (root == element) return root;
    if ([root isKindOfClass:NSControl.class] && ((NSControl *)root).cell == element) return root;
    for (NSView *child in root.subviews) {
        NSView *owner = ViewOwningAccessibilityElement(child, element);
        if (owner) return owner;
    }
    return nil;
}

static NSArray<NSNumber *> *SubviewPathToView(NSView *root, NSView *target) {
    if (!root || !target) return nil;
    if (root == target) return @[];
    for (NSUInteger i = 0; i < root.subviews.count; i++) {
        NSArray<NSNumber *> *tail = SubviewPathToView(root.subviews[i], target);
        if (!tail) continue;
        NSMutableArray<NSNumber *> *path = [NSMutableArray arrayWithObject:@(i)];
        [path addObjectsFromArray:tail];
        return path;
    }
    return nil;
}

static NSView *ViewAtSubviewPath(NSView *root, NSArray<NSNumber *> *path) {
    NSView *view = root;
    for (NSNumber *indexValue in path) {
        NSUInteger index = indexValue.unsignedIntegerValue;
        if (index >= view.subviews.count) return nil;
        view = view.subviews[index];
    }
    return view;
}

// Most refreshes change values, not structure. Updating a compatible hierarchy in
// place keeps the same AppKit/accessibility objects alive, so VoiceOver focus, keyboard
// focus, selections, and scroll state survive the 15-second live refresh. Structural
// changes (a volume/window/row appearing or disappearing) fall back to replacement plus
// the identifier-based restoration path below.
static BOOL ViewTreesCompatible(NSView *existing, NSView *fresh) {
    if (!existing || !fresh || existing.class != fresh.class) return NO;
    // Matching class and subview counts do not make two rows the same row. If one section
    // gains a row while another loses one, the flat counts still line up and an in-place
    // update would silently repoint a focused field at different data — the identifier
    // moves with it, so nothing downstream can notice. Compare identity as well as shape.
    NSString *existingIdentifier = existing.accessibilityIdentifier;
    NSString *freshIdentifier = fresh.accessibilityIdentifier;
    if (existingIdentifier != freshIdentifier && ![existingIdentifier isEqualToString:freshIdentifier])
        return NO;
    if ([existing isKindOfClass:NSScrollView.class]) {
        NSView *existingDocument = ((NSScrollView *)existing).documentView;
        NSView *freshDocument = ((NSScrollView *)fresh).documentView;
        return ViewTreesCompatible(existingDocument, freshDocument);
    }
    NSArray<NSView *> *existingSubviews = existing.subviews;
    NSArray<NSView *> *freshSubviews = fresh.subviews;
    if (existingSubviews.count != freshSubviews.count) return NO;
    for (NSUInteger i = 0; i < existingSubviews.count; i++)
        if (!ViewTreesCompatible(existingSubviews[i], freshSubviews[i])) return NO;
    return YES;
}

static void ApplyFreshViewState(NSView *existing, NSView *fresh) {
    existing.frame = fresh.frame;
    existing.autoresizingMask = fresh.autoresizingMask;
    existing.hidden = fresh.hidden;
    existing.alphaValue = fresh.alphaValue;
    existing.toolTip = fresh.toolTip;
    existing.identifier = fresh.identifier;
    existing.accessibilityIdentifier = fresh.accessibilityIdentifier;
    existing.accessibilityLabel = fresh.accessibilityLabel;
    existing.accessibilityHelp = fresh.accessibilityHelp;
    existing.accessibilityRole = fresh.accessibilityRole;

    if ([existing isKindOfClass:NSTextField.class]) {
        NSTextField *old = (NSTextField *)existing, *new = (NSTextField *)fresh;
        if (![old.stringValue isEqualToString:new.stringValue]) old.stringValue = new.stringValue;
        old.font = new.font;
        old.textColor = new.textColor;
        old.alignment = new.alignment;
        old.lineBreakMode = new.lineBreakMode;
        old.maximumNumberOfLines = new.maximumNumberOfLines;
        if (old.selectable != new.selectable) old.selectable = new.selectable;
    } else if ([existing isKindOfClass:NSButton.class]) {
        NSButton *old = (NSButton *)existing, *new = (NSButton *)fresh;
        old.title = new.title;
        old.enabled = new.enabled;
        old.state = new.state;
        old.contentTintColor = new.contentTintColor;
    } else if ([existing isKindOfClass:NSImageView.class]) {
        NSImageView *old = (NSImageView *)existing, *new = (NSImageView *)fresh;
        old.image = new.image;
        old.contentTintColor = new.contentTintColor;
    } else if ([existing isKindOfClass:Gauge.class]) {
        Gauge *old = (Gauge *)existing, *new = (Gauge *)fresh;
        old.fraction = new.fraction;
        old.color = new.color;
        old.metricLabel = new.metricLabel;
        old.accessibilityIdentifier = new.accessibilityIdentifier;
        [old setAccessibilityElement:new.isAccessibilityElement];
    } else if ([existing isKindOfClass:NSBox.class]) {
        ((NSBox *)existing).boxType = ((NSBox *)fresh).boxType;
    }

    if ([existing isKindOfClass:NSScrollView.class]) {
        NSScrollView *old = (NSScrollView *)existing, *new = (NSScrollView *)fresh;
        old.hasVerticalScroller = new.hasVerticalScroller;
        old.autohidesScrollers = new.autohidesScrollers;
        old.drawsBackground = new.drawsBackground;
        old.backgroundColor = new.backgroundColor;
        ApplyFreshViewState(old.documentView, new.documentView);
        return;
    }
    NSArray<NSView *> *existingSubviews = existing.subviews;
    NSArray<NSView *> *freshSubviews = fresh.subviews;
    for (NSUInteger i = 0; i < existingSubviews.count; i++)
        ApplyFreshViewState(existingSubviews[i], freshSubviews[i]);
}

static BOOL ReconcileViewTree(NSView *existing, NSView *fresh) {
    if (!ViewTreesCompatible(existing, fresh)) return NO;
    ApplyFreshViewState(existing, fresh);
    return YES;
}

static NSScrollView *FirstScrollView(NSView *root) {
    if ([root isKindOfClass:NSScrollView.class]) return (NSScrollView *)root;
    for (NSView *child in root.subviews) {
        NSScrollView *scroll = FirstScrollView(child);
        if (scroll) return scroll;
    }
    return nil;
}

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
// Measures segments into a draw list + total width without rendering. Split from
// BarImage so updateBar can price all three tiers per tick and draw only one.
static NSArray<NSDictionary *> *BarLayout(NSArray<NSDictionary *> *segments, NSColor *fg,
                                          CGFloat *outWidth) {
    CGFloat pt = 13, gap = 4, pad = 2;
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightRegular];
    if (!segments.count)
        segments = @[@{@"symbol": @"gauge.with.dots.needle.50percent", @"text": @"Glancebar"}];

    CGFloat w = pad;
    NSMutableArray<NSDictionary *> *draw = [NSMutableArray array];
    for (NSDictionary *seg in segments) {
        NSString *symbol = [seg[@"symbol"] isKindOfClass:NSString.class] ? seg[@"symbol"] : nil;
        NSNumber *var = [seg[@"var"] isKindOfClass:NSNumber.class] ? seg[@"var"] : nil;
        NSString *text = [seg[@"text"] isKindOfClass:NSString.class] ? seg[@"text"] : @"";
        NSImage *customImage = [seg[@"image"] isKindOfClass:NSImage.class] ? seg[@"image"] : nil;
        NSImage *sym = customImage ?: (symbol.length ? TintedSymbol(symbol, var ? var.doubleValue : -1, pt, fg) : nil);
        // When compact mode falls back to icons, empty text adds no leading space.
        NSString *drawText = text.length ? [NSString stringWithFormat:@" %@", text] : @"";
        NSSize textSize = drawText.length ? [drawText sizeWithAttributes:@{NSFontAttributeName:font}] : NSZeroSize;
        CGFloat segW = (sym ? sym.size.width : 0) + textSize.width;
        if (draw.count) w += gap*2;
        w += segW;
        [draw addObject:@{@"image": sym ?: [NSNull null], @"text": drawText,
                          @"textSize": [NSValue valueWithSize:textSize],
                          @"color": seg[@"color"] ?: fg}];
    }
    w += pad;
    if (outWidth) *outWidth = ceil(w);
    return draw;
}

static NSImage *BarImageFromLayout(NSArray<NSDictionary *> *draw, CGFloat width) {
    CGFloat gap = 4, pad = 2, h = 18;
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightRegular];
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(width, h)];
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
        if (text.length) {
            [text drawAtPoint:NSMakePoint(x, (h - textSize.height)/2)
               withAttributes:@{NSFontAttributeName:font,
                                NSForegroundColorAttributeName:(seg[@"color"] ?: NSColor.controlTextColor)}];
            x += textSize.width;
        }
    }
    [img unlockFocus];
    img.template = NO;  // we already used the adaptive fg color
    return img;
}

#pragma mark - Controller

static const CGFloat kW = 320, kPad = 16, kDetailMinW = 600, kDetailPad = 24;
// The details document follows the resizable window. It is only touched on the
// main thread; keeping the active width here avoids threading a layout argument
// through every detail-section builder.
static CGFloat kDetailW = 600;

// Identifies our observation of the status button's effectiveAppearance.
static void *kBarAppearanceContext = &kBarAppearanceContext;

@interface Controller : NSObject <NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate>
@end

@interface Controller ()
- (void)rebuildContent;
- (void)rebuildDetails;
- (void)showWelcomeIfNeeded;
- (void)refreshVolumesAsync;
- (void)refreshAIUsageAsync;
- (void)refreshLidAwakeAsync;
- (void)updateBar;
- (void)refreshVisibleSurfaces;
- (NSDictionary *)focusSnapshotForWindow:(NSWindow *)window rootView:(NSView *)root;
- (void)restoreFocus:(NSDictionary *)snapshot
             inView:(NSView *)root window:(NSWindow *)window;
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
    dispatch_queue_t _volumeQueue;
    BOOL _aiLoading, _aiRefreshPending;
    BOOL _volumesLoading, _volumesUnavailable;
    NSString *_aiSignature;
    NSString *_aiCatchUpStatus;
    BOOL _aiTotalsIncomplete;
    NSArray<NSDictionary *> *_hogs;
    NSArray<NSDictionary *> *_topCPU, *_topMem;
    NSMutableArray<NSNumber *> *_ampHistory;
    NSUInteger _sampleGen;
    CFAbsoluteTime _lastSampleTime;
    BOOL _showWatts, _showHealth, _hogsLoading, _hogsUnavailable;
    BOOL _barShowDisk, _barShowBattery, _barShowSystem, _barShowAI;
    BOOL _lidAwake, _lidAwakeReading;   // "stay awake with lid closed" state, read off-main
    BOOL _aiGatesLogged, _lastShowAI, _lastUseAccount, _lastUseCursorAccount, _lastAllowTranscripts;
    BOOL _procStatsLoading, _procStatsUnavailable;
    CFAbsoluteTime _popoverClosedAt;   // guards the status-item click-to-dismiss race
    BarTierState _barTier;             // adaptive bar width; zero-init = full tier
    BOOL _barWasOnBar;                 // arms the eviction net only after a real sighting
    NSDate *_lastMachineRefresh, *_lastAIRefresh;
    NSDate *_lastVolumeSuccess;
    NSScrollView *_popoverScroll;
}

// A catch-up pass may hold a coalesced state write. Land it before the process goes away,
// or the next launch re-reads bytes it already indexed.
//
// Never block quit on it. The AI queue is serial and a pass in flight can be parked in
// /usr/bin/security or a 15s HTTP timeout; a plain dispatch_sync would freeze the main
// thread until then. The flush is worth at most a couple of seconds of re-read, so wait
// briefly and abandon it.
- (void)applicationWillTerminate:(NSNotification *)n {
    (void)n;
    if (!_aiQueue || !_aiReader) return;
    dispatch_semaphore_t flushed = dispatch_semaphore_create(0);
    dispatch_async(_aiQueue, ^{
        [self->_aiReader flushPersistentState];
        dispatch_semaphore_signal(flushed);
    });
    if (dispatch_semaphore_wait(flushed, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC))))
        GBLog("terminate: AI state flush timed out; indexing resumes from the last write");
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud registerDefaults:@{@"showWatts": @YES, @"showHealth": @YES,
                           @"barShowDisk": @YES, @"barShowBattery": @YES,
                           @"barShowSystem": @NO, @"barShowAI": @NO,
                           @"useClaudeAccount": @NO, @"useClaudeTranscripts": @NO,
                           @"useCursorAccount": @NO}];
    _bat = ReadBattery();
    _showWatts = [ud boolForKey:@"showWatts"];
    _showHealth = [ud boolForKey:@"showHealth"];
    _barShowDisk = [ud boolForKey:@"barShowDisk"];
    _barShowBattery = [ud boolForKey:@"barShowBattery"];
    _barShowSystem = [ud boolForKey:@"barShowSystem"];
    _barShowAI = [ud boolForKey:@"barShowAI"];
    NSString *defaultsDomain = NSBundle.mainBundle.bundleIdentifier ?: @"com.iantodd.glancebar";
    NSDictionary *persisted = [ud persistentDomainForName:defaultsDomain];
    if (!persisted[@"barShowBattery"] && !_bat.valid) _barShowBattery = NO;
    _ampHistory = [NSMutableArray array];
    _vols = @[];
    _aiUsage = @[];
    _aiReader = [[AIReader alloc] initWithHomeDirectory:GBHomeDirectory()];
    _aiQueue = dispatch_queue_create("com.iantodd.glancebar.ai", DISPATCH_QUEUE_SERIAL);
    _volumeQueue = dispatch_queue_create("com.iantodd.glancebar.volumes", DISPATCH_QUEUE_SERIAL);
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
    // Re-render immediately when the menu bar flips light/dark (Light/Dark toggle, or a
    // wallpaper change that re-tints the bar). Never removed: _item lives for the whole
    // process, same as this controller.
    [_item.button addObserver:self forKeyPath:@"effectiveAppearance"
                      options:0 context:kBarAppearanceContext];

    _popover = [NSPopover new];
    _popover.behavior = NSPopoverBehaviorTransient;
    _popover.animates = YES;
    _popover.delegate = self;   // popoverWillClose: timestamps the dismiss for the toggle guard
    _popover.contentViewController = [NSViewController new];
    _popover.contentViewController.view = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,kW,10)];

    [self refresh];
    // Diagnostic: GLANCEBAR_AUTOOPEN=1 opens the popover on launch (for screenshots).
    if (getenv("GLANCEBAR_AUTOOPEN"))
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self togglePopover:nil]; });
    else if (!getenv("GLANCEBAR_SKIP_WELCOME"))
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self showWelcomeIfNeeded]; });
    [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    CFRunLoopSourceRef src = IOPSNotificationCreateRunLoopSource(PSChanged, (__bridge void *)self);
    if (src) {
        CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopDefaultMode);
        CFRelease(src);
    }
}

static void PSChanged(void *ctx) { [(__bridge Controller *)ctx refresh]; }

- (void)refreshVolumesAsync {
    if (_volumesLoading) return;
    _volumesLoading = YES;
    dispatch_async(_volumeQueue, ^{
        NSArray<Volume *> *volumes = ScanVolumes();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_volumesLoading = NO;
            // Keep last-good data if an offline mount makes a scan fail wholesale.
            if (volumes.count) {
                self->_vols = volumes;
                self->_volumesUnavailable = NO;
                self->_lastVolumeSuccess = NSDate.date;
            } else self->_volumesUnavailable = YES;
            [self updateBar];
            [self refreshVisibleSurfaces];
        });
    });
}

- (void)refresh {
    [self refreshVolumesAsync];
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
    _lastMachineRefresh = NSDate.date;
    [self refreshAIUsageAsync];
    [self refreshLidAwakeAsync];
    if (_bat.valid) {
        [_ampHistory addObject:@(_bat.amperage_mA)];
        while (_ampHistory.count > 6) [_ampHistory removeObjectAtIndex:0];
    }
    [self updateBar];
    [self refreshVisibleSurfaces];
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
    BOOL showAI = _barShowAI || _popover.isShown || _detailsWindow.isVisible;
    // Codex histories can be large. Do no transcript/database work while every AI surface
    // is hidden; opening the popover or enabling the bar segment starts/resumes indexing.
    if (!showAI) return;
    if (_aiLoading) { _aiRefreshPending = YES; return; }
    _aiLoading = YES;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL useAccount = [ud boolForKey:@"useClaudeAccount"];
    BOOL useCursorAccount = [ud boolForKey:@"useCursorAccount"];
    BOOL allowAccountFetch = showAI && useAccount;
    BOOL allowCursorAccountFetch = showAI && useCursorAccount;
    BOOL allowTranscripts = [ud boolForKey:@"useClaudeTranscripts"];
    if (!_aiGatesLogged || showAI != _lastShowAI || useAccount != _lastUseAccount ||
        useCursorAccount != _lastUseCursorAccount || allowTranscripts != _lastAllowTranscripts) {
        GBLog("gates: showAI=%d useClaudeAccount=%d useCursorAccount=%d transcripts=%d",
              showAI, useAccount, useCursorAccount, allowTranscripts);
        _aiGatesLogged = YES; _lastShowAI = showAI;
        _lastUseAccount = useAccount; _lastUseCursorAccount = useCursorAccount;
        _lastAllowTranscripts = allowTranscripts;
    }
    dispatch_async(_aiQueue, ^{
        self->_aiReader.useClaudeAccount = useAccount;
        self->_aiReader.allowClaudeAccountFetch = allowAccountFetch;
        self->_aiReader.useCursorAccount = useCursorAccount;
        self->_aiReader.allowCursorAccountFetch = allowCursorAccountFetch;
        self->_aiReader.allowClaudeTranscripts = allowTranscripts;
        NSArray<AIUsage *> *usage = [self->_aiReader read];
        BOOL needsImmediateRescan = self->_aiReader.needsImmediateRescan;
        BOOL totalsIncomplete = self->_aiReader.totalsIncomplete;
        NSString *catchUpStatus = self->_aiReader.catchUpStatus;
        NSMutableString *sig = [NSMutableString string];
        for (AIUsage *u in usage)
            [sig appendFormat:@"%@|%d|%d|%d|%lld|%lld|%lld|%lld|%lld|%lld|%lld|%lld|%.4f|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@;",
             u.name, u.available, u.limitStatusAvailable, u.limitStale,
             u.todayTokens, u.todayTokensAll, u.weekTokens, u.weekTokensAll,
             u.todaySessions, u.weekSessions, u.todayMessages, u.todayToolCalls,
             u.remainingFraction, u.resetText, u.statusText, u.statusReason,
             u.statusSource, u.extraUsage, u.limitWindows, u.models, u.lastActivity,
             u.limitUpdatedAt, u.limitRefreshError];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_aiLoading = NO;
            BOOL rerun = self->_aiRefreshPending;
            self->_aiRefreshPending = NO;
            self->_aiUsage = usage;
            self->_lastAIRefresh = NSDate.date;
            self->_aiTotalsIncomplete = totalsIncomplete;
            self->_aiCatchUpStatus = catchUpStatus;
            if (![sig isEqualToString:self->_aiSignature]) {
                self->_aiSignature = sig;
                [self updateBar];
                [self refreshVisibleSurfaces];
            }
            if (rerun) [self refreshAIUsageAsync];
            else if (needsImmediateRescan) {
                // Drain the bounded reader promptly while an AI surface is visible instead
                // of waiting 15 seconds per chunk. The visibility gate above stops this
                // loop as soon as the user hides AI.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ [self refreshAIUsageAsync]; });
            }
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
    return _vols.count ? (int)lround(_vols.firstObject.fraction*100) : -1;
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

- (NSColor *)windowColor:(double)frac {
    if (frac <= 0.15) return NSColor.systemRedColor;
    if (frac <= 0.35) return NSColor.systemOrangeColor;
    if (frac <= 0.60) return [NSColor.systemYellowColor colorWithAlphaComponent:0.9];
    return NSColor.systemGreenColor;
}

- (NSColor *)aiStatusColor:(AIUsage *)u {
    if (!u.limitStatusAvailable || u.remainingFraction < 0) return NSColor.tertiaryLabelColor;
    return [self windowColor:u.remainingFraction];
}

- (NSArray<NSDictionary *> *)barSegments {
    NSMutableArray *segments = [NSMutableArray array];
    NSColor *fg = NSColor.controlTextColor;
    if (_barShowDisk) {
        int pct = [self rootDiskPct];
        double frac = pct >= 0 ? pct / 100.0 : 0;
        NSColor *driveTextColor = pct >= 0 && frac >= 0.85 ? DiskColor(frac) : fg;
        [segments addObject:@{@"image": DriveMeterIcon(frac, fg, fg),
                              @"text": pct >= 0 ? [NSString stringWithFormat:@"%d%%", pct] : @"—",
                              @"color": driveTextColor}];
    }
    BOOL lidAwakeShown = NO;
    if (_barShowBattery) {
        NSString *text = _bat.valid ? [NSString stringWithFormat:@"%d%%", _bat.percent] : @"—";
        NSColor *color = _bat.valid && _bat.percent <= 20 && !_bat.acConnected ? BattBarColor(_bat.percent) : fg;
        NSMutableDictionary *seg = [@{@"text": text, @"color": color} mutableCopy];
        if (_bat.valid) {   // no battery (desktop Mac): text-only, no misleading empty glyph
            // The compact tier keeps exactly one high-value reading. Battery percentage
            // wins because macOS may have hidden its own percentage to make room for us.
            seg[@"compactPriority"] = @YES;
            // In the ordinary case the number alone is the densest useful form. Keep the
            // orange eye when lid-awake is active: that safety reminder outranks width.
            if (!_lidAwake) seg[@"compactTextOnly"] = @YES;
            if (_lidAwake) {
                // "Stay awake with lid closed" is on: swap the battery glyph for an orange open
                // eye — an always-visible reminder of a setting that persists across reboots.
                // The % stays: battery drain is exactly what you watch while it's forced awake.
                seg[@"image"] = TintedSymbol(@"eye.fill", -1, 13, NSColor.systemOrangeColor);
                lidAwakeShown = YES;
            } else {
                NSColor *fill = (_bat.percent <= 20 && !_bat.acConnected) ? BattBarColor(_bat.percent) : fg;
                seg[@"image"] = BatteryMeterIcon(_bat, fg, fill);
            }
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
    // The eye normally rides in the battery segment; if that segment is hidden or there's no
    // battery, still surface a standalone eye so an always-awake Mac never lacks its reminder.
    if (_lidAwake && !lidAwakeShown)
        [segments insertObject:@{@"image": TintedSymbol(@"eye.fill", -1, 13, NSColor.systemOrangeColor),
                                 @"compactPriority": @YES} atIndex:0];
    return segments;
}

- (NSString *)barAccessibilityText {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (_barShowDisk) {
        int pct = [self rootDiskPct];
        [parts addObject:pct >= 0 ? [NSString stringWithFormat:@"Storage %d percent used", pct]
                                  : @"Storage scanning"];
    }
    if (_barShowBattery) {
        [parts addObject:_bat.valid ? [NSString stringWithFormat:@"Battery %d percent%@", _bat.percent,
                                        _bat.acConnected ? @", on AC" : @""]
                                    : @"No battery detected"];
    }
    if (_barShowSystem) {
        NSString *cpu = _sys.cpuValid ? [NSString stringWithFormat:@", CPU %d percent", (int)lround(_sys.cpu * 100)] : @"";
        [parts addObject:[NSString stringWithFormat:@"System pressure %@%@", SystemPressureLevel(_sys), cpu]];
    }
    if (_barShowAI) {
        AIUsage *lowest = [self lowestAIStatus];
        [parts addObject:lowest ? [NSString stringWithFormat:@"AI, %@ %d percent remaining%@", lowest.name,
                                    (int)lround(lowest.remainingFraction * 100),
                                    lowest.limitStale ? @", cached; refresh failed" : @""]
                                : @"AI limit status unavailable"];
    }
    if (_lidAwake) [parts insertObject:@"keeping awake with lid closed" atIndex:0];
    return parts.count ? [parts componentsJoinedByString:@"; "] : @"Status";
}

// The status strip's left boundary is the notch. Glancebar is assumed leftmost in
// the strip (it is the machine's only third-party item; system items hug the right
// edge) — if that assumption breaks, the eviction net below still recovers us.
// Window bounds/PIDs from CGWindowList carry no TCC gate (names would; we read none)
// and no network — consistent with the README's privacy stance.
static double MeasuredBarGap(NSStatusItem *item) {
    NSScreen *screen = NSScreen.screens.firstObject;   // the menu bar owner
    NSWindow *win = item.button.window;
    if (!screen || !win) return -1;
    NSRect aux = screen.auxiliaryTopRightArea;         // zero rect = no notch
    if (NSWidth(aux) <= 0) return -1;
    double notchRight = NSMinX(aux);
    double rightEdge = NSMaxX(screen.frame);
    NSArray *list = CFBridgingRelease(
        CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    double leftmost = rightEdge;
    for (NSDictionary *w in list) {
        NSNumber *num = w[(__bridge NSString *)kCGWindowNumber];
        if (num.integerValue == win.windowNumber) continue;   // our own occupancy is ours to spend
        CGRect b = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)w[(__bridge NSString *)kCGWindowBounds], &b)) continue;
        // Primary display's menu-bar band only (global CG coords: its top is y=0).
        // y must be non-negative too: a display arranged ABOVE the primary sits at
        // negative CG y, and its own status items would otherwise pass as neighbours
        // and fake a tiny gap on a roomy bar.
        if (b.origin.y < 0 || b.origin.y > 1 || b.size.height > 40) continue;
        // Degenerate 1-px windows (several apps park them at the screen origin) are
        // not status items and do not occupy bar space.
        if (b.size.width < 8) continue;
        if (b.origin.x < notchRight || b.origin.x >= rightEdge) continue;
        if (b.origin.x < leftmost) leftmost = b.origin.x;
    }
    return MAX(0.0, leftmost - notchRight);
}

// Is the item sitting in the menu bar right now? Stated positively, because the
// interesting question at launch is "has it ever been in the bar", not "is it
// missing" — a window that exists but has not yet been ordered in looks identical
// to an evicted one, and treating that as eviction forced the glyph tier on every
// launch (observed live 2026-08-12: `evicted=1 tier 0→2` against a roomy 160pt gap).
// Worse, on a Mac with no notch the gap is never measurable, so that false eviction
// latched the glyph permanently. The caller therefore only trusts a NO from this
// once it has seen a YES. Judged by position: display sleep occludes every window
// without moving it, so occlusion must not read as eviction. Measured against the
// window's OWN screen — with several displays the item follows the active menu bar,
// and comparing it to the primary's top edge would false-positive forever.
static BOOL BarItemOnBar(NSStatusItem *item) {
    NSWindow *win = item.button.window;
    NSScreen *screen = win.screen ?: NSScreen.screens.firstObject;
    if (!win || !screen) return NO;
    return win.isVisible && NSMaxY(win.frame) >= NSMaxY(screen.frame) - 40;
}

- (NSArray<NSDictionary *> *)barSegmentsForTier:(int)tier full:(NSArray<NSDictionary *> *)full {
    if (tier == BarTierFull) return full;
    if (tier == BarTierCompact) {
        // Preserve one deliberately prioritised reading before falling all the way to
        // pictograms. On a MacBook that is battery percentage: it is more actionable
        // than two unlabeled meters and remains useful even in a crowded menu bar.
        NSMutableArray *priority = [NSMutableArray array];
        for (NSDictionary *seg in full) {
            if (![seg[@"compactPriority"] boolValue]) continue;
            NSMutableDictionary *d = [seg mutableCopy];
            if ([d[@"compactTextOnly"] boolValue]) {
                [d removeObjectForKey:@"image"];
                [d removeObjectForKey:@"symbol"];
                [d removeObjectForKey:@"var"];
            }
            [d removeObjectForKey:@"compactPriority"];
            [d removeObjectForKey:@"compactTextOnly"];
            [priority addObject:d];
            break;   // compact mode has one job: preserve the highest-priority reading
        }
        if (priority.count) return priority;

        // No reading opted into compact mode (for example, battery is disabled): keep
        // the old icons-only fallback so another configured metric still survives.
        // A text-only segment (a batteryless Mac renders battery as a bare "—") has
        // nothing left once the text goes: it would contribute an invisible segment
        // that still eats an inter-segment gap, and in the worst case — battery the
        // only segment — leave a 4pt blank item, which is precisely the disappearance
        // this feature exists to prevent. Drop those, and fall back to the glyph if
        // dropping them empties the tier, so tier widths stay non-increasing.
        NSMutableArray *icons = [NSMutableArray arrayWithCapacity:full.count];
        for (NSDictionary *seg in full) {
            if (!seg[@"image"] && !seg[@"symbol"]) continue;
            NSMutableDictionary *d = [seg mutableCopy];
            [d removeObjectForKey:@"text"];
            [icons addObject:d];
        }
        if (icons.count) return icons;
    }
    // Glyph tier: identity mark — except the lid-awake eye takes over, so that
    // always-visible reminder survives every tier at zero extra width.
    if (_lidAwake)
        return @[@{@"image": TintedSymbol(@"eye.fill", -1, 13, NSColor.systemOrangeColor)}];
    return @[@{@"symbol": @"gauge.with.dots.needle.50percent"}];
}

- (void)updateBar {
    // The bar is drawn into a detached, non-template NSImage, so dynamic colors like
    // controlTextColor resolve against whatever drawing appearance is current. Left to
    // default that's the *app's* appearance, which can be Light while the menu bar is
    // dark (e.g. a dark wallpaper in Light mode) — baking black text onto a dark bar.
    // Draw under the button's own menu-bar appearance instead so the neutral fg and the
    // alert colors all resolve to the shade the menu bar actually uses. barSegments
    // builds the meter icons eagerly (each lockFocuses), so it must run inside the block.
    [_item.button.effectiveAppearance performAsCurrentDrawingAppearance:^{
        NSColor *fg = NSColor.controlTextColor;
        NSArray<NSDictionary *> *full = [self barSegments];
        NSArray<NSDictionary *> *tierSegs[3] = {
            full,
            [self barSegmentsForTier:BarTierCompact full:full],
            [self barSegmentsForTier:BarTierGlyph full:full],
        };
        double widths[3]; NSArray<NSDictionary *> *draws[3];
        for (int t = 0; t < 3; t++) {
            CGFloat w = 0;
            draws[t] = BarLayout(tierSegs[t], fg, &w);
            widths[t] = w;
        }
        double gap = MeasuredBarGap(self->_item);
        // Only a fall FROM the bar is eviction. Before the item has ever been in the
        // bar there is nothing to have been evicted from, so the safety net stays
        // disarmed — otherwise every launch starts at the glyph tier, and on a Mac
        // with no notch (gap permanently unmeasurable) it would never recover.
        BOOL onBar = BarItemOnBar(self->_item);
        if (onBar) self->_barWasOnBar = YES;
        BOOL evicted = self->_barWasOnBar && !onBar;
        BarTierState chosen = ChooseBarTier(self->_barTier, gap, widths, evicted,
                                            CFAbsoluteTimeGetCurrent());
        if (getenv("GLANCEBAR_BAR_DEBUG"))
            NSLog(@"bar: gap=%.0f widths=[%.0f %.0f %.0f] onBar=%d evicted=%d tier %d→%d streak=%d",
                  gap, widths[0], widths[1], widths[2], onBar, evicted,
                  self->_barTier.tier, chosen.tier, chosen.expandStreak);
        self->_barTier = chosen;
        self->_item.button.image = BarImageFromLayout(draws[chosen.tier], widths[chosen.tier]);
    }];
    NSString *summary = [self barAccessibilityText];
    _item.button.toolTip = [@"Glancebar — " stringByAppendingString:summary];
    [_item.button setAccessibilityLabel:@"Glancebar"];
    [_item.button setAccessibilityValue:summary];
    [_item.button setAccessibilityHelp:@"Open Glancebar status and details"];
}

// SleepDisabled is read through a `pmset -g` subprocess, so — like the AI usage read — it
// must stay off the main thread (refresh fires every 15s and on IOPS bursts). Single-flight:
// a tick arriving mid-read is skipped. Only redraws the bar when the cached value changes.
- (void)refreshLidAwakeAsync {
    if (_lidAwakeReading) return;
    _lidAwakeReading = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL awake = SleepDisabledNow();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_lidAwakeReading = NO;
            if (awake != self->_lidAwake) { self->_lidAwake = awake; [self updateBar]; }
        });
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context == kBarAppearanceContext) {
        [self updateBar];   // redraw in the new menu-bar appearance
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

// Redraw whatever on-screen surfaces are currently visible.
- (void)refreshVisibleSurfaces {
    if (_popover.isShown) [self rebuildContent];
    if (_detailsWindow.isVisible) [self rebuildDetails];
}

- (NSDictionary *)focusSnapshotForWindow:(NSWindow *)window rootView:(NSView *)root {
    if (!window || !root) return @{};
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    id focused = window.accessibilityFocusedUIElement;
    NSView *focusedView = ViewOwningAccessibilityElement(root, focused);
    if (!focusedView && [focused respondsToSelector:@selector(accessibilityIdentifier)]) {
        NSString *identifier = [focused accessibilityIdentifier];
        if (identifier.length) snapshot[@"accessibility"] = identifier;
    }
    if (focusedView) {
        if (focusedView.accessibilityIdentifier.length)
            snapshot[@"accessibility"] = focusedView.accessibilityIdentifier;
        NSArray<NSNumber *> *path = SubviewPathToView(root, focusedView);
        if (path) snapshot[@"accessibilityPath"] = path;
    }
    NSResponder *responder = window.firstResponder;
    NSView *keyboardView = nil;
    BOOL hasFieldEditor = [responder isKindOfClass:NSTextView.class] && ((NSTextView *)responder).isFieldEditor;
    if (hasFieldEditor) {
        id delegate = ((NSTextView *)responder).delegate;
        if ([delegate isKindOfClass:NSView.class]) keyboardView = delegate;
        else keyboardView = ViewOwningAccessibilityElement(root, delegate);
        snapshot[@"selection"] = [NSValue valueWithRange:((NSTextView *)responder).selectedRange];
    }
    for (NSUInteger depth = 0; responder && depth < 8; depth++, responder = responder.nextResponder) {
        if (!keyboardView && [responder isKindOfClass:NSView.class] &&
            !(hasFieldEditor && depth == 0)) keyboardView = (NSView *)responder;
        if (keyboardView) break;
    }
    if (keyboardView) {
        if (keyboardView.accessibilityIdentifier.length)
            snapshot[@"keyboard"] = keyboardView.accessibilityIdentifier;
        NSArray<NSNumber *> *path = SubviewPathToView(root, keyboardView);
        if (path) snapshot[@"keyboardPath"] = path;
    }
    return snapshot;
}

- (void)restoreFocus:(NSDictionary *)snapshot
             inView:(NSView *)root window:(NSWindow *)window {
    if (!snapshot.count || !root || !window) return;
    NSView *accessibilityView = ViewWithAccessibilityIdentifier(root, snapshot[@"accessibility"]);
    if (!accessibilityView && [snapshot[@"accessibilityPath"] isKindOfClass:NSArray.class])
        accessibilityView = ViewAtSubviewPath(root, snapshot[@"accessibilityPath"]);
    if (accessibilityView) accessibilityView.accessibilityFocused = YES;
    NSView *keyboardView = ViewWithAccessibilityIdentifier(root, snapshot[@"keyboard"]);
    if (!keyboardView && [snapshot[@"keyboardPath"] isKindOfClass:NSArray.class])
        keyboardView = ViewAtSubviewPath(root, snapshot[@"keyboardPath"]);
    if (keyboardView) {
        [window makeFirstResponder:keyboardView];
        NSValue *selection = [snapshot[@"selection"] isKindOfClass:NSValue.class] ? snapshot[@"selection"] : nil;
        NSText *editor = selection ? [window fieldEditor:NO forObject:keyboardView] : nil;
        if ([editor isKindOfClass:NSTextView.class]) {
            NSRange range = selection.rangeValue;
            range.location = MIN(range.location, ((NSTextView *)editor).string.length);
            range.length = MIN(range.length, ((NSTextView *)editor).string.length - range.location);
            ((NSTextView *)editor).selectedRange = range;
        }
    }
}

#pragma mark popover

- (void)togglePopover:(id)sender {
    if (_popover.isShown) { [_popover close]; return; }
    // A transient popover dismisses on the mouse-DOWN of an outside click — and a click on
    // our own status-item button counts as "outside". The button's action then fires on
    // mouse-UP; without this guard it sees isShown==NO and reopens, so a second icon click
    // never closes the panel the way a menu would. Suppress the reopen for a frame or two
    // after any close so the icon toggles cleanly. (sender is nil for programmatic opens.)
    if (sender && CFAbsoluteTimeGetCurrent() - _popoverClosedAt < 0.20) return;
    // Reset the content view so the rebuild starts at the top on a fresh open.
    _popoverScroll = nil;
    _popover.contentViewController.view = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,kW,10)];
    [self refresh];
    [self rebuildContent];
    [_popover showRelativeToRect:_item.button.bounds ofView:_item.button preferredEdge:NSMaxYEdge];
    // Accessory (LSUIElement) apps don't activate on their own, so the popover's window
    // never becomes key — and a transient popover with no key window to resign is never
    // dismissed when the user clicks another app. Activate on open so a click elsewhere
    // (and the key-window resign it triggers) closes the panel like a normal menu.
    [NSApp activateIgnoringOtherApps:YES];
    [self refreshAIUsageAsync];
    [self beginSampling];
}

// Records when the popover last closed so togglePopover: can tell a real "open me" click
// apart from the mouse-UP that trails a transient dismiss. Fires on every close path —
// outside click, second icon click, or Escape — which is exactly the set we want to guard.
- (void)popoverWillClose:(NSNotification *)note {
    _popoverClosedAt = CFAbsoluteTimeGetCurrent();
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
    [self refreshVisibleSurfaces];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *hogs = SampleHogs(5);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_sampleGen) return;   // superseded by a newer sampling pass
            self->_hogs = hogs ? hogs : @[];
            self->_hogsLoading = NO;
            self->_hogsUnavailable = self->_hogs.count == 0;
            [self refreshVisibleSurfaces];
        });
    });
}

- (void)sampleProcessStatsAsync {
    NSUInteger gen = _sampleGen;
    _topCPU = @[];
    _topMem = @[];
    _procStatsLoading = YES;
    _procStatsUnavailable = NO;
    [self refreshVisibleSurfaces];
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
            [self refreshVisibleSurfaces];
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
    NSTextField *heading = [self text:title.uppercaseString
                                  font:[NSFont systemFontOfSize:10 weight:NSFontWeightSemibold]
                                 color:NSColor.tertiaryLabelColor
                                    at:NSMakeRect(kPad, 0, kW-2*kPad, 14)
                                 align:NSTextAlignmentLeft];
    ApplyHeadingAccessibility(heading, title);
    heading.accessibilityIdentifier = [@"popover.heading." stringByAppendingString:title.lowercaseString];
    [v addSubview:heading];
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
    g.metricLabel = [NSString stringWithFormat:@"%@ — %@", info[@"title"], right ?: @""];
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
    g.metricLabel = right.length ? [NSString stringWithFormat:@"%@ — %@", title, right] : title;
    [row addSubview:g];
    return row;
}

// The reset instant as a line of English, or nil when this provider has none to give.
// Falls back to whatever preformatted string the source supplied when there is no date
// behind it (a status-file override may hand over free text).
- (NSString *)compactResetText:(AIUsage *)u {
    NSString *phrase = ResetPhrase(u.resetAt, NSDate.date);
    if (phrase.length) return phrase;
    NSString *reset = u.resetText ?: @"";
    if (!reset.length || [reset isEqualToString:@"Not exposed locally"] ||
        [reset isEqualToString:@"Not provided"])
        return nil;
    return [NSString stringWithFormat:@"Resets %@", reset];
}

// How old the shown figure is, when it isn't live: "cached 3h ago" inline after the reset,
// "Cached 3h ago" on the dual meter's own line. WHY the refresh is failing is a plumbing
// question and lives in the details sheet, not in the one line the reader came to read.
//
// A figure restored from disk is flagged stale even when it is a minute old, because the
// reader means "I did not fetch this myself". Saying so below the poll interval would be
// a warning about nothing: a successful fetch at that age would have returned the same
// numbers. Past it, the age is the whole point.
- (NSString *)aiStalenessNote:(AIUsage *)u capitalized:(BOOL)capitalized {
    if (!u.limitStale) return nil;
    if (!u.limitUpdatedAt) return capitalized ? @"Cached figure" : @"cached";
    if (-u.limitUpdatedAt.timeIntervalSinceNow < kAccountPollInterval) return nil;
    return [NSString stringWithFormat:@"%@ %@", capitalized ? @"Cached" : @"cached",
            [self shortAgeForDate:u.limitUpdatedAt]];
}

// One line, one job: when does this quota come back. Diagnostics only get the line when
// there is no reset to report — otherwise they push the answer off the end of the row.
- (NSString *)aiStatusSubtext:(AIUsage *)u {
    NSString *note = [self aiStalenessNote:u capitalized:NO];
    // Overage has no reset to report — the paid budget is not a window that rolls over.
    NSString *lead = u.overageActive ? nil : [self compactResetText:u];
    if (!lead.length) lead = u.statusReason;
    if (lead.length)
        return note.length ? [NSString stringWithFormat:@"%@ · %@", lead, note] : lead;
    if (!u.available) return @"No local state";
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
        g.metricLabel = [NSString stringWithFormat:@"%@ quota remaining", title];
        [row addSubview:g];
    }
    [row addSubview:[self text:[self aiStatusSubtext:u] font:[NSFont systemFontOfSize:10.5] color:NSColor.secondaryLabelColor
                          at:NSMakeRect(pad, 7, inner, 14) align:NSTextAlignmentLeft]];
    return row;
}

// "Resets — 5-hour 3:10 pm · weekly Wed 9:00 am" from a window list (skips windows with
// no reset). Each window is already named beside its own gauge, so this line carries the
// clock time only — the countdown would double the width to repeat what the clock says.
- (NSString *)windowsResetSummary:(NSArray<NSDictionary *> *)windows {
    NSDate *now = NSDate.date;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *w in windows) {
        NSNumber *resets = w[@"resetsAt"];
        if (![resets isKindOfClass:NSNumber.class]) continue;
        NSString *t = ResetClockText([NSDate dateWithTimeIntervalSince1970:resets.doubleValue], now);
        if (t.length) [parts addObject:[NSString stringWithFormat:@"%@ %@", w[@"window"], t]];
    }
    return parts.count ? [@"Resets — " stringByAppendingString:[parts componentsJoinedByString:@" · "]] : @"";
}

// One popover AI card. With two or more current limit windows it draws the dual meter
// (a labeled gauge per window + a combined resets line); otherwise the compact
// single-line row, which also carries the overage / no-status fallbacks. Returns new y.
- (CGFloat)addAICard:(AIUsage *)u toView:(NSView *)root width:(CGFloat)width pad:(CGFloat)pad at:(CGFloat)y {
    NSArray<NSDictionary *> *windows = u.limitWindows;
    if (u.overageActive || windows.count < 2) {
        [root addSubview:[self aiStatusRow:u width:width pad:pad at:y]];
        return y + 44;
    }
    CGFloat inner = width - 2*pad;
    [root addSubview:[self text:(u.name ?: @"AI") font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]
                          color:nil at:NSMakeRect(pad, y, inner, 15) align:NSTextAlignmentLeft]];
    y += 19;
    for (NSDictionary *w in windows) {
        double frac = [w[@"remainingFraction"] doubleValue];
        NSString *right = [NSString stringWithFormat:@"%d%% left", (int)lround(frac * 100)];
        [root addSubview:[self compactSignalRow:(w[@"window"] ?: @"window") right:right fraction:frac
                                          color:[self windowColor:frac] width:width pad:pad at:y]];
        y += 28;
    }
    NSString *resets = [self windowsResetSummary:windows];
    if (resets.length) {
        [root addSubview:[self text:resets font:[NSFont systemFontOfSize:10.5] color:NSColor.secondaryLabelColor
                              at:NSMakeRect(pad, y, inner, 14) align:NSTextAlignmentLeft]];
        y += 16;
    }
    NSString *staleness = [self aiStalenessNote:u capitalized:YES];
    if (staleness.length) {
        [root addSubview:[self text:staleness font:[NSFont systemFontOfSize:10.5]
                              color:NSColor.systemOrangeColor
                                 at:NSMakeRect(pad, y, inner, 14) align:NSTextAlignmentLeft]];
        y += 16;
    }
    return y + 6;
}

- (NSString *)aiOverviewText {
    AIUsage *lowest = [self lowestAIStatus];
    if (lowest) return [NSString stringWithFormat:@"%@ %@ remaining · %@",
                        lowest.name, [self aiPercentText:lowest], [self aiStatusSubtext:lowest]];
    return @"Limit status unavailable";
}

- (NSString *)shortAgeForDate:(NSDate *)date {
    if (!date) return @"pending";
    NSTimeInterval age = MAX(0, -date.timeIntervalSinceNow);
    if (age < 10) return @"now";
    if (age < 60) return [NSString stringWithFormat:@"%.0fs ago", age];
    if (age < 3600) return [NSString stringWithFormat:@"%.0fm ago", age / 60.0];
    return [NSString stringWithFormat:@"%.0fh ago", age / 3600.0];
}

- (void)rebuildContent {
    NSView *previousView = _popover.contentViewController.view;
    NSWindow *popoverWindow = previousView.window;
    NSDictionary *focusSnapshot = [self focusSnapshotForWindow:popoverWindow rootView:previousView];
    FlippedView *root = [[PopoverRootView alloc] initWithFrame:NSMakeRect(0,0,kW,2000)];
    CGFloat y = kPad;

    // ---------- STORAGE ----------
    [root addSubview:[self sectionHeader:@"Storage" at:y]]; y += 22;
    if (!_vols.count) {
        NSString *status = _volumesLoading ? @"Scanning mounted volumes…" : @"Storage information unavailable";
        NSTextField *statusField = [self text:status font:[NSFont systemFontOfSize:12]
                                          color:NSColor.secondaryLabelColor
                                             at:NSMakeRect(kPad, y, kW-2*kPad, 16)
                                          align:NSTextAlignmentLeft];
        statusField.accessibilityIdentifier = @"popover.storage.status";
        [root addSubview:statusField];
        y += 24;
    }
    for (Volume *v in _vols) {
        NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, 50)];
        CGFloat inner = kW - 2*kPad;
        NSImage *ic = [NSImage imageWithSystemSymbolName:(v.isInternal ? @"internaldrive" : @"externaldrive")
                                accessibilityDescription:nil];
        NSImageView *iv = [NSImageView imageViewWithImage:ic];
        iv.contentTintColor = NSColor.secondaryLabelColor; iv.frame = NSMakeRect(kPad, 31, 17, 15);
        [row addSubview:iv];
        NSString *volumeID = [@"popover.storage" stringByAppendingString:v.path ?: v.name];
        NSTextField *nameField = [self text:v.name font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                                          color:nil at:NSMakeRect(kPad+23, 31, inner-23-46, 16)
                                          align:NSTextAlignmentLeft];
        nameField.accessibilityIdentifier = [volumeID stringByAppendingString:@".name"];
        [row addSubview:nameField];
        NSTextField *percentField = [self text:[NSString stringWithFormat:@"%d%%", (int)lround(v.fraction*100)]
                                             font:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular]
                                            color:NSColor.secondaryLabelColor
                                               at:NSMakeRect(kW-kPad-46, 31, 46, 16)
                                            align:NSTextAlignmentRight];
        percentField.accessibilityIdentifier = [volumeID stringByAppendingString:@".percent"];
        [row addSubview:percentField];
        Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(kPad, 22, inner, 5)];
        g.fraction = v.fraction; g.color = DiskColor(v.fraction);
        g.metricLabel = [NSString stringWithFormat:@"%@ storage used", v.name];
        g.accessibilityIdentifier = [volumeID stringByAppendingString:@".gauge"];
        [row addSubview:g];
        NSTextField *capacityField = [self text:[NSString stringWithFormat:@"%@ of %@ used · %@ free",
                                                FmtBytes(v.used), FmtBytes(v.total), FmtBytes(v.available)]
                                             font:[NSFont systemFontOfSize:11]
                                            color:NSColor.secondaryLabelColor
                                               at:NSMakeRect(kPad, 4, inner, 14)
                                            align:NSTextAlignmentLeft];
        capacityField.accessibilityIdentifier = [volumeID stringByAppendingString:@".capacity"];
        [row addSubview:capacityField];
        [root addSubview:row]; y += 54;
    }
    if (_volumesUnavailable && _vols.count) {
        NSString *age = _lastVolumeSuccess
            ? [NSString stringWithFormat:@"Using last storage reading (%@) · scan unavailable",
               [self shortAgeForDate:_lastVolumeSuccess]]
            : @"Using last storage reading · scan unavailable";
        [root addSubview:[self text:age font:[NSFont systemFontOfSize:10.5]
                              color:NSColor.systemOrangeColor at:NSMakeRect(kPad, y, kW-2*kPad, 14)
                              align:NSTextAlignmentLeft]];
        y += 18;
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
            if (_bat.percent <= 20) {
                big = [NSString stringWithFormat:@"%d%% remaining", _bat.percent];
                sub = @"At or below the 20% reserve";
            } else {
                int minutes = MinutesTo20(_bat, [self avgAmp]);
                big = minutes >= 0 ? [NSString stringWithFormat:@"%@ until 20%%", FmtDuration(minutes)]
                                   : @"Estimating time until 20%";
                sub = [NSString stringWithFormat:@"%d%% remaining", _bat.percent];
            }
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
        chargeGauge.metricLabel = @"Battery charge";
        [hl addSubview:chargeGauge];
        [root addSubview:hl]; y += 54;
    } else {
        [root addSubview:[self text:@"No battery detected" font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                              color:nil at:NSMakeRect(kPad, y, kW-2*kPad, 17) align:NSTextAlignmentLeft]];
        [root addSubview:[self text:@"Energy-impact sampling remains available on desktop Macs"
                              font:[NSFont systemFontOfSize:10.5] color:NSColor.secondaryLabelColor
                                at:NSMakeRect(kPad, y+18, kW-2*kPad, 14) align:NSTextAlignmentLeft]];
        y += 38;
    }

    // The POWER column is a relative one-sample signal, not a percentage of battery drain.
    [root addSubview:[self text:@"Sampled energy impact" font:[NSFont systemFontOfSize:11]
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
        NSString *right = [NSString stringWithFormat:@"%d%% sample", (int)lround(share * 100)];
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
    NSView *sys = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, 64)];
    CGFloat inner = kW - 2*kPad;
    [sys addSubview:[self text:[NSString stringWithFormat:@"%@ system pressure", sysLevel]
                          font:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold]
                         color:SystemPressureColor(sysLevel)
                            at:NSMakeRect(kPad, 43, inner, 18) align:NSTextAlignmentLeft]];
    NSTextField *systemSummary = [self text:SystemSummaryText(_sys) font:[NSFont systemFontOfSize:10.5]
                                      color:NSColor.secondaryLabelColor at:NSMakeRect(kPad, 15, inner, 27)
                                      align:NSTextAlignmentLeft];
    systemSummary.lineBreakMode = NSLineBreakByWordWrapping;
    systemSummary.maximumNumberOfLines = 2;
    [sys addSubview:systemSummary];
    Gauge *cpuGauge = [[Gauge alloc] initWithFrame:NSMakeRect(kPad, 5, inner, 4)];
    cpuGauge.fraction = _sys.cpuValid ? _sys.cpu : 0;
    cpuGauge.color = _sys.cpuValid ? CPUColor(_sys.cpu) : NSColor.tertiaryLabelColor;
    cpuGauge.metricLabel = @"Overall CPU utilization";
    if (!_sys.cpuValid) [cpuGauge setAccessibilityElement:NO];
    [sys addSubview:cpuGauge];
    [root addSubview:sys]; y += 68;

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
            y = [self addAICard:u toView:root width:kW pad:kPad at:y];
        }
    }

    // ---------- fixed footer ----------
    // Keep navigation and freshness visible even when the metric document is
    // taller than the current display and needs to scroll.
    y += 8;
    NSString *freshness = _aiTotalsIncomplete && _aiCatchUpStatus.length
        ? _aiCatchUpStatus
        : [NSString stringWithFormat:@"Checked: machine %@ · AI %@",
           [self shortAgeForDate:_lastMachineRefresh], [self shortAgeForDate:_lastAIRefresh]];
    const CGFloat footerH = 54;
    // Fills windowBackgroundColor in drawRect: instead of freezing it into a CALayer CGColor,
    // so the footer follows a live Light/Dark switch like the panel above it.
    PopoverRootView *footer = [[PopoverRootView alloc] initWithFrame:NSMakeRect(0, 0, kW, footerH)];
    NSTextField *freshnessField = [self text:freshness font:[NSFont systemFontOfSize:9.5]
                                           color:NSColor.tertiaryLabelColor
                                              at:NSMakeRect(kPad, 3, kW-2*kPad, 13)
                                           align:NSTextAlignmentLeft];
    freshnessField.accessibilityIdentifier = @"popover.freshness";
    [footer addSubview:freshnessField];
    [footer addSubview:[self dividerAt:20]];
    NSView *foot = [[NSView alloc] initWithFrame:NSMakeRect(0, 27, kW, 24)];
    NSButton *opts = [NSButton buttonWithTitle:@"Options" target:self action:@selector(showOptions:)];
    opts.bordered = NO; opts.font = [NSFont systemFontOfSize:12]; opts.contentTintColor = NSColor.secondaryLabelColor;
    opts.frame = NSMakeRect(kPad-4, 0, 66, 22); opts.toolTip = @"Configure Glancebar";
    opts.accessibilityIdentifier = @"popover.options";
    [opts setAccessibilityHelp:@"Configure metrics, privacy, and startup behavior"];
    [foot addSubview:opts];
    NSButton *details = [NSButton buttonWithTitle:@"Details…" target:self action:@selector(showDetails:)];
    details.bordered = NO; details.font = [NSFont systemFontOfSize:12];
    details.contentTintColor = NSColor.secondaryLabelColor;
    details.frame = NSMakeRect(kPad+70, 0, 76, 22); details.toolTip = @"Open the detailed status window";
    details.accessibilityIdentifier = @"popover.details";
    [foot addSubview:details];
    NSButton *quit = [NSButton buttonWithTitle:@"Quit" target:NSApp action:@selector(terminate:)];
    quit.bordered = NO; quit.font = [NSFont systemFontOfSize:12]; quit.contentTintColor = NSColor.secondaryLabelColor;
    quit.frame = NSMakeRect(kW-kPad-50, 0, 50, 22); quit.alignment = NSTextAlignmentRight;
    quit.accessibilityIdentifier = @"popover.quit";
    [foot addSubview:quit];
    [footer addSubview:foot];

    root.frame = NSMakeRect(0, 0, kW, MAX(y, 1));
    NSScreen *screen = _item.button.window.screen ?: NSScreen.mainScreen;
    CGFloat maxPopoverH = 720;
    if (screen) maxPopoverH = MIN(maxPopoverH, MAX(360.0, screen.visibleFrame.size.height - 72.0));
    NSView *freshView = nil;
    NSScrollView *freshScroll = nil;
    if (y + footerH > maxPopoverH) {
        // Preserve position across periodic rebuilds; togglePopover: clears the
        // stored scroll view so every newly opened popover starts at the top.
        CGFloat offset = _popoverScroll ? _popoverScroll.contentView.bounds.origin.y : 0;
        CGFloat scrollH = maxPopoverH - footerH;
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, kW, scrollH)];
        scroll.borderType = NSNoBorder;
        scroll.drawsBackground = YES;
        scroll.backgroundColor = NSColor.windowBackgroundColor;
        scroll.hasVerticalScroller = YES;
        scroll.autohidesScrollers = YES;
        scroll.documentView = root;
        [scroll.contentView scrollToPoint:NSMakePoint(0, MIN(offset, MAX(0, y - scrollH)))];
        [scroll reflectScrolledClipView:scroll.contentView];
        FlippedView *container = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kW, maxPopoverH)];
        footer.frame = NSMakeRect(0, scrollH, kW, footerH);
        [container addSubview:scroll];
        [container addSubview:footer];
        freshView = container;
        freshScroll = scroll;
        _popover.contentSize = NSMakeSize(kW, maxPopoverH);
    } else {
        footer.frame = NSMakeRect(0, y, kW, footerH);
        [root addSubview:footer];
        root.frame = NSMakeRect(0, 0, kW, y + footerH);
        freshView = root;
        _popover.contentSize = NSMakeSize(kW, y + footerH);
    }
    if (ReconcileViewTree(previousView, freshView)) {
        _popoverScroll = FirstScrollView(previousView);
    } else {
        _popover.contentViewController.view = freshView;
        _popoverScroll = freshScroll;
        [self restoreFocus:focusSnapshot inView:freshView window:popoverWindow];
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
    w.enabled = _bat.valid;
    NSMenuItem *h = [m addItemWithTitle:@"Show battery health" action:@selector(toggleHealth:) keyEquivalent:@""];
    h.target = self; h.state = _showHealth ? NSControlStateValueOn : NSControlStateValueOff;
    h.enabled = _bat.valid;
    [m addItem:NSMenuItem.separatorItem];

    // Reflects the live system setting, not a stored preference: it is global and other
    // tools can change it, so the checkmark must read the real state.
    NSMenuItem *lidAwake = [m addItemWithTitle:@"Stay awake with lid closed"
                                        action:@selector(toggleStayAwake:) keyEquivalent:@""];
    lidAwake.target = self;
    lidAwake.state = SleepDisabledNow() ? NSControlStateValueOn : NSControlStateValueOff;
    [m addItem:NSMenuItem.separatorItem];

    NSMenuItem *privacyTitle = [m addItemWithTitle:@"AI & privacy" action:nil keyEquivalent:@""];
    privacyTitle.enabled = NO;
    NSMenuItem *transcripts = [m addItemWithTitle:@"Claude transcript token totals"
                                           action:@selector(toggleClaudeTranscripts:) keyEquivalent:@""];
    transcripts.target = self;
    transcripts.state = [NSUserDefaults.standardUserDefaults boolForKey:@"useClaudeTranscripts"]
        ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *acct = [m addItemWithTitle:@"Claude account status via Keychain/API"
                                    action:@selector(toggleClaudeAccount:) keyEquivalent:@""];
    acct.target = self;
    acct.state = [NSUserDefaults.standardUserDefaults boolForKey:@"useClaudeAccount"]
        ? NSControlStateValueOn : NSControlStateValueOff;
    if (CursorServicePresent(GBHomeDirectory())) {
        NSMenuItem *cursorAcct = [m addItemWithTitle:@"Cursor account status via local session/API"
                                              action:@selector(toggleCursorAccount:) keyEquivalent:@""];
        cursorAcct.target = self;
        cursorAcct.state = [NSUserDefaults.standardUserDefaults boolForKey:@"useCursorAccount"]
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [m addItem:NSMenuItem.separatorItem];

    SMAppServiceStatus loginStatus = SMAppService.mainAppService.status;
    NSMenuItem *login = [m addItemWithTitle:loginStatus == SMAppServiceStatusRequiresApproval
                                            ? @"Launch at Login (approve in System Settings)"
                                            : @"Launch at Login"
                                      action:@selector(toggleLaunchAtLogin:) keyEquivalent:@""];
    login.target = self;
    login.state = loginStatus == SMAppServiceStatusEnabled ? NSControlStateValueOn
                : loginStatus == SMAppServiceStatusRequiresApproval ? NSControlStateValueMixed
                : NSControlStateValueOff;
    NSMenuItem *refresh = [m addItemWithTitle:@"Refresh Now" action:@selector(refreshNow:) keyEquivalent:@"r"];
    refresh.target = self;
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *activity = [m addItemWithTitle:@"Open Activity Monitor…" action:@selector(openActivityMonitor:) keyEquivalent:@""];
    activity.target = self;
    NSMenuItem *diskUtility = [m addItemWithTitle:@"Open Disk Utility…" action:@selector(openDiskUtility:) keyEquivalent:@""];
    diskUtility.target = self;
    NSMenuItem *about = [m addItemWithTitle:@"About Glancebar…" action:@selector(showAbout:) keyEquivalent:@""];
    about.target = self;
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height) inView:sender];
}

// Explicit opt-in: `/usr/bin/security` performs an Apple-tool-authorized, normally silent
// read of Claude Code's credential, so the app itself—not a system prompt—must explain and
// obtain consent before the token is read or sent to Anthropic's usage endpoint.
- (void)toggleClaudeAccount:(id)s {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL enabling = ![ud boolForKey:@"useClaudeAccount"];
    if (enabling) {
        NSAlert *alert = [NSAlert new];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = @"Enable Claude account status?";
        alert.informativeText = @"Glancebar will ask Apple’s /usr/bin/security tool to read the Claude Code OAuth credential from your Keychain. That read is normally silent—macOS may not show its own permission dialog. Glancebar keeps the token only in memory and sends it only to api.anthropic.com to request your usage limits, at most every 15 minutes. This relies on Claude Code’s private Keychain layout and an undocumented account endpoint, so it may stop working after an update.";
        [alert addButtonWithTitle:@"Enable"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    [ud setBool:enabling forKey:@"useClaudeAccount"];
    if (!enabling) dispatch_async(_aiQueue, ^{ [self->_aiReader forgetClaudeAccountCredentials]; });
    [self refresh];
}
- (void)toggleCursorAccount:(id)s {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL enabling = ![ud boolForKey:@"useCursorAccount"];
    if (enabling) {
        NSAlert *alert = [NSAlert new];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = @"Enable Cursor account status?";
        alert.informativeText = @"Glancebar will read the signed-in Cursor session token from Cursor’s local state database (state.vscdb). It keeps the token only in memory and sends it only to api2.cursor.sh to request your included usage limits, at most every 15 minutes. This relies on Cursor’s private local layout and undocumented account endpoints, so it may stop working after an update.";
        [alert addButtonWithTitle:@"Enable"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    [ud setBool:enabling forKey:@"useCursorAccount"];
    if (!enabling) dispatch_async(_aiQueue, ^{ [self->_aiReader forgetCursorAccountCredentials]; });
    [self refresh];
}
- (void)toggleClaudeTranscripts:(id)s {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL enabling = ![ud boolForKey:@"useClaudeTranscripts"];
    if (enabling) {
        NSAlert *alert = [NSAlert new];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = @"Read Claude transcript usage counters?";
        alert.informativeText = @"Claude transcript files contain conversation records. Glancebar scans them locally and never sends transcript contents over the network. Its mode-0600 local index stores only file offsets/identity, daily token totals, timestamps, and opaque message hashes—not prompts or responses.";
        [alert addButtonWithTitle:@"Enable Local Scan"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    [ud setBool:enabling forKey:@"useClaudeTranscripts"];
    [self refresh];
}
// Keeps the Mac running with the lid closed by flipping the SleepDisabled system power
// setting via an admin prompt (chosen over caffeinate/IOPMAssertion, which only defeat
// idle sleep — never clamshell/lid-close sleep). No preference is stored: the live setting
// is the single source of truth — SleepDisabled persists in the system power plist across
// reboots, and reading it live keeps the checkmark accurate however it was last changed.
- (void)toggleStayAwake:(id)s {
    BOOL enabling = !SleepDisabledNow();
    if (enabling) {
        NSAlert *alert = [NSAlert new];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = @"Stay awake with the lid closed?";
        alert.informativeText = @"Glancebar will ask macOS for your administrator password to run pmset, which keeps this Mac running when the lid is closed (the display sleeps but the system stays awake). While it’s on, the Mac won’t sleep on its own at all. This setting persists across restarts until you turn it back off, so switch it off when you’re done—otherwise a closed Mac can keep running and overheat in a bag. No background helper is installed; Glancebar runs pmset only when you flip this switch.";
        [alert addButtonWithTitle:@"Continue"];
        [alert addButtonWithTitle:@"Cancel"];
        [NSApp activateIgnoringOtherApps:YES];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    // Run the (modal) admin prompt off the main thread so the app stays responsive; the
    // menu re-reads the live state on next open, so a cancel or failure needs no rollback.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SetSleepDisabledViaAdmin(enabling);
        // Re-read the true state (whether it applied or the user cancelled) and update the
        // bar eye promptly, rather than waiting up to 15s for the next refresh tick.
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshLidAwakeAsync]; });
    });
}
- (void)toggleWatts:(id)s { _showWatts = !_showWatts; [NSUserDefaults.standardUserDefaults setBool:_showWatts forKey:@"showWatts"]; [self rebuildContent]; }
- (void)toggleHealth:(id)s { _showHealth = !_showHealth; [NSUserDefaults.standardUserDefaults setBool:_showHealth forKey:@"showHealth"]; [self rebuildContent]; }

- (void)showError:(NSError *)error title:(NSString *)title {
    NSAlert *alert = error ? [NSAlert alertWithError:error] : [NSAlert new];
    if (title.length) alert.messageText = title;
    [alert runModal];
}

- (BOOL)setLaunchAtLoginEnabled:(BOOL)enabled showErrors:(BOOL)showErrors {
    NSError *error = nil;
    BOOL ok = enabled ? [SMAppService.mainAppService registerAndReturnError:&error]
                      : [SMAppService.mainAppService unregisterAndReturnError:&error];
    if (!ok && showErrors) [self showError:error title:@"Couldn’t update Launch at Login"];
    if (ok && enabled && SMAppService.mainAppService.status == SMAppServiceStatusRequiresApproval && showErrors) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Approval required";
        alert.informativeText = @"macOS requires approval in System Settings → General → Login Items. Glancebar has submitted the request.";
        [alert runModal];
    }
    return ok;
}

- (void)toggleLaunchAtLogin:(id)sender {
    BOOL enabled = SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    [self setLaunchAtLoginEnabled:!enabled showErrors:YES];
}

- (void)showWelcomeIfNeeded {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if ([ud boolForKey:@"hasShownWelcome"]) return;
    [ud setBool:YES forKey:@"hasShownWelcome"];
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"Glancebar is ready";
    alert.informativeText = @"Glancebar now lives in your menu bar. Click its meters for storage, battery, system, and AI status. Options controls what appears and keeps Claude access off until you explicitly enable it. If the item is hidden by a MacBook notch, free one menu-bar slot in Control Center.";
    [alert addButtonWithTitle:@"Got It"];
    [alert addButtonWithTitle:@"Launch at Login"];
    if ([alert runModal] == NSAlertSecondButtonReturn)
        [self setLaunchAtLoginEnabled:YES showErrors:YES];
}

- (void)refreshNow:(id)sender {
    [self refresh];
    if (_popover.isShown || _detailsWindow.isVisible) [self beginSampling];
}

- (void)openApplicationAtPath:(NSString *)path title:(NSString *)title {
    NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:configuration
                                     completionHandler:^(NSRunningApplication *__unused app, NSError *error) {
        if (error) dispatch_async(dispatch_get_main_queue(), ^{ [self showError:error title:title]; });
    }];
}

- (void)openActivityMonitor:(id)sender {
    [self openApplicationAtPath:@"/System/Applications/Utilities/Activity Monitor.app"
                          title:@"Couldn’t open Activity Monitor"];
}

- (void)openDiskUtility:(id)sender {
    [self openApplicationAtPath:@"/System/Applications/Utilities/Disk Utility.app"
                          title:@"Couldn’t open Disk Utility"];
}

- (void)showAbout:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Glancebar %@", GBVersion];
    alert.informativeText = @"One native menu-bar item for machine and AI status. No third-party dependencies; no network access unless Claude account status is explicitly enabled.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)saveBarOption:(NSString *)key value:(BOOL)value {
    [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
    [self updateBar];
    [self refreshAIUsageAsync];
    if (_popover.isShown) [self rebuildContent];
}

- (void)toggleBarDisk:(id)s {
    _barShowDisk = !_barShowDisk; [self saveBarOption:@"barShowDisk" value:_barShowDisk];
}
- (void)toggleBarBattery:(id)s {
    _barShowBattery = !_barShowBattery; [self saveBarOption:@"barShowBattery" value:_barShowBattery];
}
- (void)toggleBarSystem:(id)s {
    _barShowSystem = !_barShowSystem; [self saveBarOption:@"barShowSystem" value:_barShowSystem];
}
- (void)toggleBarAI:(id)s {
    _barShowAI = !_barShowAI; [self saveBarOption:@"barShowAI" value:_barShowAI];
}

- (Volume *)primaryVolume {
    for (Volume *v in _vols) if ([v.path isEqualToString:@"/"]) return v;
    return _vols.firstObject;
}

- (NSString *)batteryStatusText {
    if (!_bat.valid) return @"No battery detected";
    if (_bat.acConnected) {
        if (_bat.fullyCharged || _bat.percent >= 100) return @"Fully charged · on AC";
        if (_bat.isCharging) return [NSString stringWithFormat:@"%d%% · charging", _bat.percent];
        return [NSString stringWithFormat:@"%d%% · on AC, not charging", _bat.percent];
    }
    if (_bat.percent <= 20)
        return [NSString stringWithFormat:@"%d%% · at or below the 20%% reserve", _bat.percent];
    int minutes = MinutesTo20(_bat, [self avgAmp]);
    return minutes >= 0 ? [NSString stringWithFormat:@"%d%% · %@ until 20%%",
                           _bat.percent, FmtDuration(minutes)]
                        : [NSString stringWithFormat:@"%d%% · estimating time until 20%%", _bat.percent];
}

- (NSString *)batteryPowerText {
    if (!_bat.valid) return @"Unavailable";
    if (_bat.voltage_mV <= 0 || _bat.amperage_mA == 0) return _bat.acConnected ? @"On AC" : @"Estimating";
    double watts = fabs((double)_bat.amperage_mA) * _bat.voltage_mV / 1e6;
    return [NSString stringWithFormat:@"%@ %.1f W",
            _bat.amperage_mA < 0 ? @"Drawing" : @"Charging at", watts];
}

// `sectionKey` is a stable semantic path for the section this heading OPENS — never the
// section it follows, and never a build-order index. Rows added after it inherit it.
- (void)addDetailHeading:(NSString *)title key:(NSString *)sectionKey
                      to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width {
    if (*y > kDetailPad) *y += 8;
    FlippedView *detailRoot = [root isKindOfClass:FlippedView.class] ? (FlippedView *)root : nil;
    NSTextField *heading = [self text:title.uppercaseString
                                  font:[NSFont systemFontOfSize:10 weight:NSFontWeightSemibold]
                                 color:NSColor.tertiaryLabelColor
                                    at:NSMakeRect(kDetailPad, *y, width-2*kDetailPad, 14)
                                 align:NSTextAlignmentLeft];
    ApplyHeadingAccessibility(heading, title);
    NSString *key = sectionKey.length ? sectionKey.lowercaseString : title.lowercaseString;
    NSString *scope = root.accessibilityIdentifier ?: @"details";
    heading.accessibilityIdentifier = DisambiguatedDetailKey(detailRoot, @"id",
        [NSString stringWithFormat:@"%@.heading.%@", scope, key]);
    if (detailRoot) detailRoot.accessibilitySection = key;
    [root addSubview:heading];
    *y += 24;
}

- (void)addDetailKey:(NSString *)key value:(NSString *)value to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width {
    [self addDetailKey:key value:value identifierKey:key to:root y:y width:width];
}

// `identifierKey` names the row for focus restoration and defaults to the displayed key.
// Pass a distinct one wherever the display text is lossy — ShortModelName maps both
// "claude-opus-4-8" and "opus-4-8" onto "opus-4-8", and the rows are ordered by usage, so
// a key built from the display name would swap identifiers as token counts cross.
- (void)addDetailKey:(NSString *)key value:(NSString *)value identifierKey:(NSString *)identifierKey
                  to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width {
    CGFloat keyW = 126;
    CGFloat valueW = width - 2*kDetailPad - keyW;
    NSFont *valueFont = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    NSString *safeValue = value ?: @"";
    NSRect measured = [safeValue boundingRectWithSize:NSMakeSize(valueW, CGFLOAT_MAX)
                                               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                            attributes:@{NSFontAttributeName: valueFont}];
    CGFloat rowH = MAX(16, ceil(measured.size.height));
    [root addSubview:[self text:key font:[NSFont systemFontOfSize:12] color:NSColor.secondaryLabelColor
                            at:NSMakeRect(kDetailPad, *y, keyW, 16) align:NSTextAlignmentLeft]];
    NSTextField *field = [self text:safeValue font:valueFont color:nil
                                at:NSMakeRect(kDetailPad+keyW, *y, valueW, rowH)
                             align:NSTextAlignmentLeft];
    field.lineBreakMode = NSLineBreakByWordWrapping;
    field.maximumNumberOfLines = 0;
    field.selectable = YES;
    field.accessibilityIdentifier = DetailIdentifier(root, @"value", identifierKey.length ? identifierKey : key);
    [root addSubview:field];
    *y += MAX(24, rowH + 8);
}

- (void)addDetailStatus:(NSString *)status to:(NSView *)root y:(CGFloat *)y width:(CGFloat)width {
    CGFloat fieldW = width - 2*kDetailPad;
    NSFont *font = [NSFont systemFontOfSize:12];
    NSString *safeStatus = status ?: @"";
    NSRect measured = [safeStatus boundingRectWithSize:NSMakeSize(fieldW, CGFLOAT_MAX)
                                                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                             attributes:@{NSFontAttributeName: font}];
    CGFloat rowH = MAX(16, ceil(measured.size.height));
    NSTextField *field = [self text:safeStatus font:font color:NSColor.secondaryLabelColor
                                at:NSMakeRect(kDetailPad, *y, fieldW, rowH) align:NSTextAlignmentLeft];
    field.lineBreakMode = NSLineBreakByWordWrapping;
    field.maximumNumberOfLines = 0;
    field.selectable = YES;
    field.accessibilityIdentifier = DetailIdentifier(root, @"status", @"status");
    [root addSubview:field];
    *y += MAX(24, rowH + 8);
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
    root.accessibilityIdentifier = @"details.overview";
    CGFloat y = kDetailPad;
    [self addDetailHeading:@"Overview" key:@"overview" to:root y:&y width:kDetailW];

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

    [self addDetailHeading:@"Top Signals" key:@"top-signals" to:root y:&y width:kDetailW];
    if (_hogsLoading || _procStatsLoading) {
        [self addDetailStatus:@"Measuring top apps…" to:root y:&y width:kDetailW];
    } else if (_hogsUnavailable || _procStatsUnavailable) {
        [self addDetailStatus:@"One or more app samplers are unavailable" to:root y:&y width:kDetailW];
    } else if (!_hogs.count && !_topCPU.count && !_topMem.count) {
        [self addDetailStatus:@"No sampled app activity" to:root y:&y width:kDetailW];
    } else {
        if (_hogs.count) {
            NSDictionary *h = _hogs.firstObject;
            double total = [_hogs.firstObject[@"totalImpact"] doubleValue];
            if (total <= 0) for (NSDictionary *row in _hogs) total += [row[@"impact"] doubleValue];
            double share = total > 0 ? [h[@"impact"] doubleValue] / total : 0;
            [root addSubview:[self processMetricRow:h right:[NSString stringWithFormat:@"Sample %d%%", (int)lround(share * 100)]
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

- (void)revealVolume:(NSButton *)sender {
    NSString *path = sender.identifier;
    if (!path.length) return;
    [NSWorkspace.sharedWorkspace selectFile:nil inFileViewerRootedAtPath:path];
}

- (NSScrollView *)storageDetailsView {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 420)];
    root.accessibilityIdentifier = @"details.storage";
    CGFloat y = kDetailPad;
    [self addDetailHeading:@"Storage" key:@"storage" to:root y:&y width:kDetailW];
    if (_volumesUnavailable && _vols.count)
        [self addDetailStatus:@"Volume scan unavailable; showing the last successful reading"
                           to:root y:&y width:kDetailW];
    if (!_vols.count) {
        [self addDetailStatus:_volumesLoading ? @"Scanning mounted volumes…" : @"Storage information unavailable"
                           to:root y:&y width:kDetailW];
    }
    for (Volume *volume in _vols) {
        [self addDetailHeading:volume.name key:[@"volume." stringByAppendingString:volume.path ?: volume.name] to:root y:&y width:kDetailW];
        [root addSubview:[self compactSignalRow:@"Used"
                                          right:[NSString stringWithFormat:@"%d%%", (int)lround(volume.fraction * 100)]
                                       fraction:volume.fraction color:DiskColor(volume.fraction)
                                          width:kDetailW pad:kDetailPad at:y]];
        y += 34;
        [self addDetailKey:@"Used" value:FmtBytes(volume.used) to:root y:&y width:kDetailW];
        [self addDetailKey:@"Available" value:FmtBytes(volume.available) to:root y:&y width:kDetailW];
        [self addDetailKey:@"Capacity" value:FmtBytes(volume.total) to:root y:&y width:kDetailW];
        [self addDetailKey:@"Mount point" value:volume.path to:root y:&y width:kDetailW];
        NSButton *reveal = [NSButton buttonWithTitle:@"Reveal in Finder" target:self action:@selector(revealVolume:)];
        reveal.identifier = volume.path;
        reveal.bezelStyle = NSBezelStyleRounded;
        reveal.frame = NSMakeRect(kDetailPad, y, 126, 28);
        reveal.accessibilityIdentifier = [@"details.reveal." stringByAppendingString:volume.path];
        reveal.toolTip = [NSString stringWithFormat:@"Reveal %@ in Finder", volume.name];
        [root addSubview:reveal];
        y += 36;
    }
    return [self detailScrollForRoot:root height:y];
}

- (NSScrollView *)batteryDetailsView {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 520)];
    root.accessibilityIdentifier = @"details.battery";
    CGFloat y = kDetailPad;
    [self addDetailHeading:@"Battery" key:@"battery" to:root y:&y width:kDetailW];
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
        if (!_bat.acConnected && _bat.percent > 20)
            [self addDetailKey:@"Until 20%" value:FmtDuration(MinutesTo20(_bat, [self avgAmp])) to:root y:&y width:kDetailW];
        if (_bat.designCap_mAh > 0) {
            NSString *health = [NSString stringWithFormat:@"%d%% · %ld/%ld mAh · %ld cycles",
                                (int)lround(100.0*_bat.rawMax_mAh/_bat.designCap_mAh),
                                _bat.rawMax_mAh, _bat.designCap_mAh, _bat.cycleCount];
            [self addDetailKey:@"Health" value:health to:root y:&y width:kDetailW];
        }
    }

    [self addDetailHeading:@"Sampled Energy Impact" key:@"energy" to:root y:&y width:kDetailW];
    if (_hogsLoading) {
        [self addDetailStatus:@"Measuring top apps…" to:root y:&y width:kDetailW];
    } else if (_hogsUnavailable) {
        [self addDetailStatus:@"Energy-impact sampler unavailable" to:root y:&y width:kDetailW];
    } else if (!_hogs.count) {
        [self addDetailStatus:@"No active sampled apps" to:root y:&y width:kDetailW];
    } else {
        double total = [_hogs.firstObject[@"totalImpact"] doubleValue];
        if (total <= 0) for (NSDictionary *h in _hogs) total += [h[@"impact"] doubleValue];
        for (NSDictionary *h in _hogs) {
            double share = total > 0 ? [h[@"impact"] doubleValue] / total : 0;
            NSString *right = [NSString stringWithFormat:@"Sample %d%%", (int)lround(share * 100)];
            [root addSubview:[self processMetricRow:h right:right fraction:share color:PressureColor(share)
                                              width:kDetailW pad:kDetailPad at:y]];
            y += 42;
        }
    }
    return [self detailScrollForRoot:root height:y];
}

- (NSScrollView *)aiDetailsView {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 620)];
    root.accessibilityIdentifier = @"details.ai";
    CGFloat y = kDetailPad;
    [self addDetailHeading:@"AI Status" key:@"ai-status" to:root y:&y width:kDetailW];

    for (AIUsage *u in _aiUsage) {
        NSString *providerKey = (u.name ?: @"ai").lowercaseString;
        [self addDetailHeading:u.name ?: @"AI" key:[@"ai-status." stringByAppendingString:providerKey]
                            to:root y:&y width:kDetailW];
        [self addDetailKey:@"Remaining" value:[self aiPercentText:u] to:root y:&y width:kDetailW];
        [self addDetailKey:@"Reset" value:[self aiResetDetailText:u] to:root y:&y width:kDetailW];
        if (u.limitWindows.count >= 2)
            for (NSDictionary *w in u.limitWindows) {
                NSNumber *resets = [w[@"resetsAt"] isKindOfClass:NSNumber.class] ? w[@"resetsAt"] : nil;
                NSString *reset = resets ? ResetTextFromDate([NSDate dateWithTimeIntervalSince1970:resets.doubleValue]) : nil;
                int pct = (int)lround([w[@"remainingFraction"] doubleValue] * 100);
                NSString *val = reset.length ? [NSString stringWithFormat:@"%d%% left · resets %@", pct, reset]
                                             : [NSString stringWithFormat:@"%d%% left", pct];
                [self addDetailKey:w[@"window"] value:val to:root y:&y width:kDetailW];
            }
        [self addDetailKey:@"Status" value:u.limitStatusAvailable ? (u.statusReason ?: @"Limit status available")
                                                                   : (u.statusReason ?: @"No limit status source")
                        to:root y:&y width:kDetailW];
        if (u.limitUpdatedAt)
            [self addDetailKey:@"Limit checked" value:ClockText(u.limitUpdatedAt) to:root y:&y width:kDetailW];
        if (u.limitRefreshError.length)   // why the figure above is the last-known one
            [self addDetailKey:@"Refresh" value:u.limitRefreshError to:root y:&y width:kDetailW];
        if (u.extraUsage)
            [self addDetailKey:@"Extra usage" value:u.extraUsage to:root y:&y width:kDetailW];
        if (u.statusSource)
            [self addDetailKey:@"Status source" value:u.statusSource to:root y:&y width:kDetailW];
    }

    [self addDetailHeading:@"Privacy & Sources" key:@"privacy" to:root y:&y width:kDetailW];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [self addDetailKey:@"Claude account"
                 value:[ud boolForKey:@"useClaudeAccount"] ? @"On · Keychain token + api.anthropic.com" : @"Off · no Keychain/API access"
                    to:root y:&y width:kDetailW];
    [self addDetailKey:@"Claude transcripts"
                 value:[ud boolForKey:@"useClaudeTranscripts"] ? @"On · local ~/.claude/projects JSONL" : @"Off · transcripts not read"
                    to:root y:&y width:kDetailW];
    if (CursorServicePresent(GBHomeDirectory())) {
        [self addDetailKey:@"Cursor account"
                     value:[ud boolForKey:@"useCursorAccount"]
                        ? @"On · local Cursor session + api2.cursor.sh" : @"Off · no Cursor session/API access"
                        to:root y:&y width:kDetailW];
    }
    [self addDetailKey:@"Codex logs" value:@"On · local ~/.codex session JSONL"
                    to:root y:&y width:kDetailW];
    NSString *statusPath = [GBHomeDirectory() stringByAppendingPathComponent:@".glancebar/ai-status.json"];
    NSString *statusState = [NSFileManager.defaultManager fileExistsAtPath:statusPath]
        ? @"Present · overrides provider gauges" : @"Not found";
    [self addDetailKey:@"Status file" value:statusState to:root y:&y width:kDetailW];

    [self addDetailHeading:@"Local History" key:@"local-history" to:root y:&y width:kDetailW];
    for (AIUsage *u in _aiUsage) {
        NSString *providerKey = (u.name ?: @"ai").lowercaseString;
        [self addDetailHeading:u.name ?: @"AI" key:[@"local-history." stringByAppendingString:providerKey]
                            to:root y:&y width:kDetailW];
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
            // Keyed by provider: Claude gaining a Models section must not rename Codex's rows.
            [self addDetailHeading:@"Models"
                               key:[NSString stringWithFormat:@"local-history.%@.models", providerKey]
                                to:root y:&y width:kDetailW];
            for (NSDictionary *model in u.models) {
                NSString *rawName = [model[@"name"] isKindOfClass:NSString.class] ? model[@"name"] : nil;
                NSString *name = ShortModelName(rawName);
                long long tokens = [model[@"tokens"] isKindOfClass:NSNumber.class] ? [model[@"tokens"] longLongValue] : 0;
                NSNumber *sessions = [model[@"sessions"] isKindOfClass:NSNumber.class] ? model[@"sessions"] : nil;
                NSString *right = tokens > 0 && sessions ? [NSString stringWithFormat:@"%@ · %@ sessions", FmtTokenCount(tokens), sessions]
                                : sessions ? [NSString stringWithFormat:@"%@ sessions", sessions]
                                : FmtTokenCount(tokens);
                // The raw model id, not the shortened display name: rows are ordered by usage.
                [self addDetailKey:name value:right identifierKey:rawName ?: name
                                to:root y:&y width:kDetailW];
            }
        }
    }
    return [self detailScrollForRoot:root height:y];
}

- (NSScrollView *)systemDetailsView {
    FlippedView *root = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kDetailW, 620)];
    root.accessibilityIdentifier = @"details.system";
    CGFloat y = kDetailPad;
    [self addDetailHeading:@"System" key:@"system" to:root y:&y width:kDetailW];
    [self addDetailKey:@"Pressure" value:SystemPressureLevel(_sys) to:root y:&y width:kDetailW];
    [self addDetailKey:@"CPU" value:CPUStatusText(_sys) to:root y:&y width:kDetailW];
    [self addDetailKey:@"Memory" value:MemoryStatusText(_sys) to:root y:&y width:kDetailW];
    [self addDetailKey:@"Swap" value:SwapStatusText(_sys) to:root y:&y width:kDetailW];

    [self addDetailHeading:@"Top CPU" key:@"top-cpu" to:root y:&y width:kDetailW];
    if (_procStatsLoading) {
        [self addDetailStatus:@"Measuring top apps…" to:root y:&y width:kDetailW];
    } else if (_procStatsUnavailable) {
        [self addDetailStatus:@"Process sampler unavailable" to:root y:&y width:kDetailW];
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

    [self addDetailHeading:@"Top Memory" key:@"top-memory" to:root y:&y width:kDetailW];
    if (_procStatsLoading) {
        [self addDetailStatus:@"Measuring top apps…" to:root y:&y width:kDetailW];
    } else if (_procStatsUnavailable) {
        [self addDetailStatus:@"Process sampler unavailable" to:root y:&y width:kDetailW];
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
    if ([identifier isEqualToString:@"storage"]) return [self storageDetailsView];
    if ([identifier isEqualToString:@"battery"]) return [self batteryDetailsView];
    if ([identifier isEqualToString:@"system"]) return [self systemDetailsView];
    if ([identifier isEqualToString:@"ai"]) return [self aiDetailsView];
    return nil;
}

- (void)rebuildDetails {
    if (!_detailsWindow) return;
    NSDictionary *focusSnapshot = [self focusSnapshotForWindow:_detailsWindow
                                                       rootView:_detailsWindow.contentView];

    // The tab chrome consumes roughly 60pt at the initial 660pt window width.
    // Grow the document with the window while retaining the original readable
    // minimum, then rebuild rows so wrapping and right-aligned gauges stay exact.
    kDetailW = MAX(kDetailMinW, _detailsWindow.contentView.bounds.size.width - 60.0);

    NSTabView *tabs = nil;
    for (NSView *subview in _detailsWindow.contentView.subviews) {
        if ([subview isKindOfClass:NSTabView.class]) { tabs = (NSTabView *)subview; break; }
    }

    if (!tabs) {   // first build: create the shell once
        NSRect bounds = _detailsWindow.contentView ? _detailsWindow.contentView.bounds : NSMakeRect(0, 0, 660, 520);
        if (bounds.size.width < 100 || bounds.size.height < 100) bounds = NSMakeRect(0, 0, 660, 520);
        NSView *content = [[NSView alloc] initWithFrame:bounds];
        tabs = [[NSTabView alloc] initWithFrame:NSInsetRect(content.bounds, 12, 12)];
        tabs.accessibilityIdentifier = @"details.tabs";
        tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [tabs addTabViewItem:[self detailTabWithIdentifier:@"overview" title:@"Overview" view:[self detailViewForIdentifier:@"overview"]]];
        [tabs addTabViewItem:[self detailTabWithIdentifier:@"storage" title:@"Storage" view:[self detailViewForIdentifier:@"storage"]]];
        [tabs addTabViewItem:[self detailTabWithIdentifier:@"battery" title:@"Battery" view:[self detailViewForIdentifier:@"battery"]]];
        [tabs addTabViewItem:[self detailTabWithIdentifier:@"system" title:@"System" view:[self detailViewForIdentifier:@"system"]]];
        [tabs addTabViewItem:[self detailTabWithIdentifier:@"ai" title:@"AI" view:[self detailViewForIdentifier:@"ai"]]];
        [content addSubview:tabs];
        _detailsWindow.contentView = content;
        [self restoreFocus:focusSnapshot inView:content window:_detailsWindow];
        return;
    }

    // Periodic refresh: swap each tab's document in place — the tab view, selection,
    // first responder, and per-tab scroll position all survive.
    for (NSTabViewItem *item in tabs.tabViewItems) {
        NSScrollView *fresh = [self detailViewForIdentifier:item.identifier];
        if (!fresh) continue;
        NSRect existingFrame = item.view.frame;
        if (ReconcileViewTree(item.view, fresh)) {
            item.view.frame = existingFrame;  // NSTabView owns the viewport geometry
            continue;
        }
        CGFloat offset = 0;
        if ([item.view isKindOfClass:NSScrollView.class])
            offset = ((NSScrollView *)item.view).contentView.bounds.origin.y;
        item.view = fresh;
        CGFloat maxOffset = MAX(0, fresh.documentView.frame.size.height - fresh.contentView.bounds.size.height);
        [fresh.contentView scrollToPoint:NSMakePoint(0, MIN(offset, maxOffset))];
        [fresh reflectScrolledClipView:fresh.contentView];
    }
    [self restoreFocus:focusSnapshot inView:_detailsWindow.contentView window:_detailsWindow];
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
        _detailsWindow.delegate = self;
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

- (void)windowDidResize:(NSNotification *)notification {
    if (notification.object != _detailsWindow || !_detailsWindow.isVisible) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(rebuildDetails) object:nil];
    [self performSelector:@selector(rebuildDetails) withObject:nil afterDelay:0.04];
}

@end

#pragma mark - main

static id JSONValue(id value) { return value ?: NSNull.null; }
static NSNumber *JSONBool(BOOL value) { return value ? @YES : @NO; }

static BOOL IsJSONBoolean(id value) {
    return value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static NSString *ISODateString(NSDate *date) {
    if (!date) return nil;
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    return [iso stringFromDate:date];
}

static NSArray<NSDictionary *> *DumpProcessRows(NSArray<NSDictionary *> *rows, BOOL cpuRows) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSDictionary *info = ProcessDisplayInfo(row);
        NSMutableDictionary *item = [@{
            @"name": JSONValue(row[@"name"]),
            @"title": JSONValue(info[@"title"]),
            @"detail": JSONValue(info[@"detail"]),
            @"commands": [row[@"commands"] isKindOfClass:NSArray.class] ? row[@"commands"] : @[],
            @"bytes": @([row[@"bytes"] unsignedLongLongValue])
        } mutableCopy];
        if (cpuRows) item[@"cpuPercent"] = @(GroupCPUShare(row) * 100.0);
        [out addObject:item];
    }
    return out;
}

static NSString *RequestedAIAccountError(NSArray<AIUsage *> *usage, BOOL accountRequested) {
    if (!accountRequested) return nil;
    for (AIUsage *item in usage)
        if ([item.name isEqualToString:@"Claude"] && item.limitRefreshError.length)
            return item.limitRefreshError;
    return nil;
}

static NSString *RequestedCursorAccountError(NSArray<AIUsage *> *usage, BOOL accountRequested) {
    if (!accountRequested) return nil;
    for (AIUsage *item in usage)
        if ([item.name isEqualToString:@"Cursor"] && item.limitRefreshError.length)
            return item.limitRefreshError;
    return nil;
}

static NSDictionary *DumpSnapshot(BOOL allowOnline) {
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    snapshot[@"schemaVersion"] = @1;
    snapshot[@"glancebarVersion"] = GBVersion;
    snapshot[@"generatedAt"] = ISODateString(NSDate.date);

    NSArray<Volume *> *volumes = ScanVolumes();
    NSMutableArray *volumeRows = [NSMutableArray array];
    for (Volume *volume in volumes) {
        [volumeRows addObject:@{
            @"name": volume.name ?: @"",
            @"path": volume.path ?: @"",
            @"internal": JSONBool(volume.isInternal),
            @"totalBytes": @(volume.total),
            @"usedBytes": @(volume.used),
            @"availableBytes": @(volume.available),
            @"usedPercent": @(volume.fraction * 100.0)
        }];
    }
    snapshot[@"storage"] = @{
        @"available": JSONBool(volumeRows.count > 0),
        @"error": volumeRows.count ? NSNull.null : @"No mounted volume data",
        @"volumes": volumeRows
    };

    BatteryState battery = ReadBattery();
    int minutesTo20 = battery.valid && !battery.acConnected && battery.percent > 20
        ? MinutesTo20(battery, battery.amperage_mA) : -1;
    NSNumber *watts = battery.valid && battery.voltage_mV > 0 && battery.amperage_mA != 0
        ? @(fabs((double)battery.amperage_mA) * battery.voltage_mV / 1e6) : nil;
    NSNumber *health = battery.valid && battery.designCap_mAh > 0 && battery.rawMax_mAh >= 0
        ? @(100.0 * battery.rawMax_mAh / battery.designCap_mAh) : nil;
    snapshot[@"battery"] = @{
        @"available": JSONBool(battery.valid),
        @"error": battery.valid ? NSNull.null : @"No battery detected",
        @"percent": battery.valid ? @(battery.percent) : NSNull.null,
        @"acConnected": JSONBool(battery.valid && battery.acConnected),
        @"charging": JSONBool(battery.valid && battery.isCharging),
        @"fullyCharged": JSONBool(battery.valid && battery.fullyCharged),
        @"atOrBelowReserve": JSONBool(battery.valid && !battery.acConnected && battery.percent <= 20),
        @"minutesUntil20Percent": minutesTo20 >= 0 ? @(minutesTo20) : NSNull.null,
        @"powerWatts": JSONValue(watts),
        @"healthPercent": JSONValue(health),
        @"cycleCount": battery.valid && battery.cycleCount >= 0 ? @(battery.cycleCount) : NSNull.null
    };

    NSArray *hogs = SampleHogs(5);
    double impactTotal = [hogs.firstObject[@"totalImpact"] doubleValue];
    if (impactTotal <= 0) for (NSDictionary *row in hogs) impactTotal += [row[@"impact"] doubleValue];
    NSMutableArray *impactRows = [NSMutableArray array];
    for (NSDictionary *row in hogs) {
        NSDictionary *info = ProcessDisplayInfo(row);
        double share = impactTotal > 0 ? [row[@"impact"] doubleValue] / impactTotal : 0;
        [impactRows addObject:@{
            @"name": JSONValue(row[@"name"]),
            @"title": JSONValue(info[@"title"]),
            @"detail": JSONValue(info[@"detail"]),
            @"commands": [row[@"commands"] isKindOfClass:NSArray.class] ? row[@"commands"] : @[],
            @"sampleSharePercent": @(share * 100.0)
        }];
    }
    snapshot[@"sampledEnergyImpact"] = @{
        @"available": JSONBool(impactRows.count > 0),
        @"error": impactRows.count ? NSNull.null : @"Energy-impact sample unavailable",
        @"rows": impactRows
    };

    CPUCounters previous = ReadCPUCounters();
    [NSThread sleepForTimeInterval:0.25];
    SystemState system = ReadSystemState(&previous);
    NSDictionary *stats = SampleProcessStats(5);
    NSArray *cpuRows = [stats[@"cpu"] isKindOfClass:NSArray.class] ? stats[@"cpu"] : @[];
    NSArray *memoryRows = [stats[@"memory"] isKindOfClass:NSArray.class] ? stats[@"memory"] : @[];
    NSMutableArray<NSString *> *systemErrors = [NSMutableArray array];
    if (!system.cpuValid) [systemErrors addObject:@"CPU sample unavailable"];
    if (!system.memValid) [systemErrors addObject:@"Memory sample unavailable"];
    if (!system.swapValid) [systemErrors addObject:@"Swap sample unavailable"];
    if (!cpuRows.count && !memoryRows.count) [systemErrors addObject:@"Process sample unavailable"];
    snapshot[@"system"] = @{
        @"available": JSONBool(systemErrors.count == 0),
        @"error": systemErrors.count ? [systemErrors componentsJoinedByString:@"; "] : NSNull.null,
        @"pressure": SystemPressureLevel(system),
        @"cpuPercent": system.cpuValid ? @(system.cpu * 100.0) : NSNull.null,
        @"memoryPressure": MemoryPressureLevel(system),
        @"memoryTotalBytes": system.memValid ? @(system.memTotal) : NSNull.null,
        @"memoryUsedBytes": system.memValid ? @(system.memUsed) : NSNull.null,
        @"memoryAvailableBytes": system.memValid ? @(system.memAvailable) : NSNull.null,
        @"swapUsedBytes": system.swapValid ? @(system.swapUsed) : NSNull.null,
        @"topCPU": DumpProcessRows(cpuRows, YES),
        @"topMemory": DumpProcessRows(memoryRows, NO),
        @"processSampleAvailable": JSONBool(cpuRows.count > 0 || memoryRows.count > 0)
    };

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{@"barShowAI": @NO, @"useClaudeAccount": @NO, @"useClaudeTranscripts": @NO,
                                 @"useCursorAccount": @NO}];
    BOOL accountEnabled = [defaults boolForKey:@"useClaudeAccount"];
    BOOL accountRequested = allowOnline && accountEnabled;
    BOOL cursorAccountEnabled = [defaults boolForKey:@"useCursorAccount"];
    BOOL cursorAccountRequested = allowOnline && cursorAccountEnabled;
    AIReader *reader = [[AIReader alloc] initWithHomeDirectory:GBHomeDirectory()];
    // Consent (toggle) controls whether the last-known account cache is used and whether
    // forget runs. Online permission only gates the network fetch — otherwise offline
    // --dump would call forget and wipe the disk cache.
    reader.useClaudeAccount = accountEnabled;
    reader.allowClaudeAccountFetch = accountRequested;
    reader.useCursorAccount = cursorAccountEnabled;
    reader.allowCursorAccountFetch = cursorAccountRequested;
    reader.allowClaudeTranscripts = [defaults boolForKey:@"useClaudeTranscripts"];
    NSArray<AIUsage *> *usage = [reader readUntilCaughtUpWithTimeLimit:30.0];
    NSMutableArray *providers = [NSMutableArray array];
    BOOL anyAIAvailable = NO;
    for (AIUsage *item in usage) {
        anyAIAvailable |= item.available || item.limitStatusAvailable;
        [providers addObject:@{
            @"name": item.name ?: @"AI",
            @"available": JSONBool(item.available),
            @"limitStatusAvailable": JSONBool(item.limitStatusAvailable && item.remainingFraction >= 0),
            @"limitStale": JSONBool(item.limitStale),
            @"remainingPercent": item.limitStatusAvailable && item.remainingFraction >= 0
                ? @(item.remainingFraction * 100.0) : NSNull.null,
            @"limitUpdatedAt": JSONValue(ISODateString(item.limitUpdatedAt)),
            @"limitRefreshError": JSONValue(item.limitRefreshError),
            @"reset": JSONValue(item.resetText),
            @"status": JSONValue(item.statusText),
            @"statusReason": JSONValue(item.statusReason),
            @"statusSource": JSONValue(item.statusSource),
            @"extraUsage": JSONValue(item.extraUsage),
            @"source": JSONValue(item.source),
            @"overageActive": JSONBool(item.overageActive),
            @"todayFreshTokens": @(item.todayTokens),
            @"todayAllTokens": @(item.todayTokensAll),
            @"sevenDayFreshTokens": @(item.weekTokens),
            @"sevenDayAllTokens": @(item.weekTokensAll),
            @"todaySessions": @(item.todaySessions),
            @"windows": item.limitWindows ?: @[],
            @"models": item.models ?: @[],
            @"lastActivity": JSONValue(ISODateString(item.lastActivity)),
            @"diagnostics": JSONValue(item.diagnostics)
        }];
    }
    NSString *accountError = RequestedAIAccountError(usage, accountRequested);
    NSString *cursorAccountError = RequestedCursorAccountError(usage, cursorAccountRequested);
    NSMutableArray<NSString *> *aiErrors = [NSMutableArray array];
    if (!anyAIAvailable) [aiErrors addObject:@"No local AI status available"];
    if (reader.totalsIncomplete) [aiErrors addObject:@"AI history indexing incomplete"];
    if (accountError.length) [aiErrors addObject:[@"Claude account: " stringByAppendingString:accountError]];
    if (cursorAccountError.length)
        [aiErrors addObject:[@"Cursor account: " stringByAppendingString:cursorAccountError]];
    snapshot[@"ai"] = @{
        @"available": JSONBool(anyAIAvailable),
        @"error": aiErrors.count ? [aiErrors componentsJoinedByString:@"; "] : NSNull.null,
        @"onlineAllowed": JSONBool(allowOnline),
        @"accountEnabled": JSONBool(accountEnabled),
        @"accountRequested": JSONBool(accountRequested),
        @"cursorAccountEnabled": JSONBool(cursorAccountEnabled),
        @"cursorAccountRequested": JSONBool(cursorAccountRequested),
        @"transcriptsEnabled": JSONBool([defaults boolForKey:@"useClaudeTranscripts"]),
        @"totalsIncomplete": JSONBool(reader.totalsIncomplete),
        @"catchUpProgress": @(reader.catchUpProgress),
        @"catchUpStatus": reader.catchUpStatus,
        @"providers": providers
    };

    NSMutableArray<NSString *> *partialSources = [NSMutableArray array];
    if (!volumes.count) [partialSources addObject:@"storage"];
    if (!battery.valid) [partialSources addObject:@"battery"];
    if (!impactRows.count) [partialSources addObject:@"sampledEnergyImpact"];
    if (!system.cpuValid || !system.memValid) [partialSources addObject:@"system"];
    if (!system.swapValid) [partialSources addObject:@"system.swap"];
    if (!cpuRows.count && !memoryRows.count) [partialSources addObject:@"system.processes"];
    if (reader.totalsIncomplete) [partialSources addObject:@"ai.history"];
    if (!anyAIAvailable) [partialSources addObject:@"ai"];
    if (accountError.length) [partialSources addObject:@"ai.account"];
    if (cursorAccountError.length) [partialSources addObject:@"ai.cursorAccount"];
    snapshot[@"partialSources"] = partialSources;
    snapshot[@"status"] = partialSources.count ? @"partial" : @"complete";
    return snapshot;
}

static const char *UTF8(NSString *string) { return string.UTF8String ?: ""; }

static NSString *DumpBooleanTypeError(NSDictionary *snapshot) {
    NSArray<NSDictionary *> *groups = @[
        @{ @"name": @"storage", @"value": snapshot[@"storage"] ?: @{},
           @"keys": @[@"available"] },
        @{ @"name": @"battery", @"value": snapshot[@"battery"] ?: @{},
           @"keys": @[@"available", @"acConnected", @"charging", @"fullyCharged", @"atOrBelowReserve"] },
        @{ @"name": @"sampledEnergyImpact", @"value": snapshot[@"sampledEnergyImpact"] ?: @{},
           @"keys": @[@"available"] },
        @{ @"name": @"system", @"value": snapshot[@"system"] ?: @{},
           @"keys": @[@"available", @"processSampleAvailable"] },
        @{ @"name": @"ai", @"value": snapshot[@"ai"] ?: @{},
           @"keys": @[@"available", @"onlineAllowed", @"accountEnabled", @"accountRequested",
                       @"cursorAccountEnabled", @"cursorAccountRequested",
                       @"transcriptsEnabled", @"totalsIncomplete"] }
    ];
    for (NSDictionary *group in groups) {
        NSDictionary *value = group[@"value"];
        for (NSString *key in group[@"keys"])
            if (!IsJSONBoolean(value[key]))
                return [NSString stringWithFormat:@"%@.%@ must be a JSON boolean", group[@"name"], key];
    }
    for (NSDictionary *volume in snapshot[@"storage"][@"volumes"] ?: @[])
        if (!IsJSONBoolean(volume[@"internal"])) return @"storage.volumes[].internal must be a JSON boolean";
    for (NSDictionary *provider in snapshot[@"ai"][@"providers"] ?: @[])
        for (NSString *key in @[@"available", @"limitStatusAvailable", @"limitStale", @"overageActive"])
            if (!IsJSONBoolean(provider[key]))
                return [NSString stringWithFormat:@"ai.providers[].%@ must be a JSON boolean", key];
    return nil;
}

static void PrintHumanDump(NSDictionary *snapshot) {
    NSDictionary *storage = snapshot[@"storage"];
    NSArray *volumes = storage[@"volumes"];
    if (!volumes.count) printf("disk  unavailable\n");
    for (NSDictionary *volume in volumes)
        printf("disk  %-16s %3d%%  %s free\n", UTF8(volume[@"name"]),
               (int)lround([volume[@"usedPercent"] doubleValue]),
               UTF8(FmtBytes([volume[@"availableBytes"] longLongValue])));

    NSDictionary *battery = snapshot[@"battery"];
    if (![battery[@"available"] boolValue]) printf("batt  no battery detected\n");
    else {
        printf("batt  %d%% (%s)\n", [battery[@"percent"] intValue],
               [battery[@"acConnected"] boolValue] ? "on AC" : "on battery");
        if ([battery[@"atOrBelowReserve"] boolValue]) printf("      at or below the 20%% reserve\n");
        else if (battery[@"minutesUntil20Percent"] != NSNull.null)
            printf("      %s until 20%%\n", UTF8(FmtDuration([battery[@"minutesUntil20Percent"] intValue])));
        if (battery[@"healthPercent"] != NSNull.null) {
            if (battery[@"cycleCount"] != NSNull.null)
                printf("      health %d%% · %ld cycles\n",
                       (int)lround([battery[@"healthPercent"] doubleValue]),
                       [battery[@"cycleCount"] longValue]);
            else printf("      health %d%%\n", (int)lround([battery[@"healthPercent"] doubleValue]));
        }
    }

    printf("sampled energy impact:\n");
    NSArray *impact = snapshot[@"sampledEnergyImpact"][@"rows"];
    if (!impact.count) printf("  unavailable\n");
    for (NSDictionary *row in impact)
        printf("  %3d%%  %-18s %s\n", (int)lround([row[@"sampleSharePercent"] doubleValue]),
               UTF8(row[@"title"]), UTF8(row[@"detail"]));

    NSDictionary *system = snapshot[@"system"];
    NSString *cpu = system[@"cpuPercent"] == NSNull.null ? @"CPU unknown"
        : [NSString stringWithFormat:@"CPU %d%%", (int)lround([system[@"cpuPercent"] doubleValue])];
    NSString *memory = system[@"memoryAvailableBytes"] == NSNull.null ? @"Memory unknown"
        : [NSString stringWithFormat:@"Memory pressure %@ · %@ available", system[@"memoryPressure"],
           FmtBytes([system[@"memoryAvailableBytes"] longLongValue])];
    NSString *swap = system[@"swapUsedBytes"] == NSNull.null ? @"Swap unknown"
        : [system[@"swapUsedBytes"] unsignedLongLongValue] == 0 ? @"Swap none"
        : [NSString stringWithFormat:@"Swap %@", FmtBytes([system[@"swapUsedBytes"] longLongValue])];
    printf("system %s · %s · %s\n", UTF8(cpu), UTF8(memory), UTF8(swap));
    NSArray *topCPU = system[@"topCPU"], *topMemory = system[@"topMemory"];
    if (!topCPU.count && !topMemory.count) printf("top apps unavailable\n");
    if (topCPU.count) {
        printf("top cpu:\n");
        for (NSDictionary *row in topCPU)
            printf("  %3.0f%%  %-18s %s\n", [row[@"cpuPercent"] doubleValue], UTF8(row[@"title"]), UTF8(row[@"detail"]));
    }
    if (topMemory.count) {
        printf("top memory:\n");
        for (NSDictionary *row in topMemory)
            printf("  %6s  %-18s %s\n", UTF8(FmtBytes([row[@"bytes"] longLongValue])),
                   UTF8(row[@"title"]), UTF8(row[@"detail"]));
    }

    NSDictionary *ai = snapshot[@"ai"];
    printf("ai toggles: useClaudeAccount=%s · useCursorAccount=%s · useClaudeTranscripts=%s · onlinePermission=%s · accountRequest=%s · cursorAccountRequest=%s\n",
           [ai[@"accountEnabled"] boolValue] ? "on" : "off",
           [ai[@"cursorAccountEnabled"] boolValue] ? "on" : "off",
           [ai[@"transcriptsEnabled"] boolValue] ? "on" : "off",
           [ai[@"onlineAllowed"] boolValue] ? "allowed" : "off",
           [ai[@"accountRequested"] boolValue] ? "enabled" : "off",
           [ai[@"cursorAccountRequested"] boolValue] ? "enabled" : "off");
    printf("ai status: %s\n", UTF8(ai[@"catchUpStatus"]));
    for (NSDictionary *provider in ai[@"providers"]) {
        NSString *remaining = provider[@"remainingPercent"] == NSNull.null ? @"remaining unavailable"
            : [NSString stringWithFormat:@"%d%% remaining", (int)lround([provider[@"remainingPercent"] doubleValue])];
        NSString *reset = provider[@"reset"] == NSNull.null ? @"reset unavailable"
            : [NSString stringWithFormat:@"resets %@", provider[@"reset"]];
        NSString *reason = provider[@"statusReason"] == NSNull.null ? @"" : provider[@"statusReason"];
        printf("  %-7s %s · %s · today %s · 7d %s%s%s\n", UTF8(provider[@"name"]), UTF8(remaining), UTF8(reset),
               UTF8(FmtTokenCount([provider[@"todayFreshTokens"] longLongValue])),
               UTF8(FmtTokenCount([provider[@"sevenDayFreshTokens"] longLongValue])),
               reason.length ? " · " : "", UTF8(reason));
        for (NSDictionary *window in provider[@"windows"]) {
            NSString *windowReset = window[@"resetsAt"] ? ResetTextFromDate(
                [NSDate dateWithTimeIntervalSince1970:[window[@"resetsAt"] doubleValue]]) : @"not provided";
            printf("          %-8s %d%% left · resets %s\n", UTF8(window[@"window"]),
                   (int)lround([window[@"remainingFraction"] doubleValue] * 100), UTF8(windowReset));
        }
        if (provider[@"diagnostics"] != NSNull.null)
            printf("          why: %s\n", UTF8(provider[@"diagnostics"]));
    }
    NSArray *partialSources = snapshot[@"partialSources"];
    if (partialSources.count)
        printf("status partial (%s)\n", UTF8([partialSources componentsJoinedByString:@", "]));
    else printf("status complete\n");
}

static BOOL PrintJSONDump(NSDictionary *snapshot) {
    NSString *schemaError = DumpBooleanTypeError(snapshot);
    if (schemaError) {
        fprintf(stderr, "Glancebar: JSON schema validation failed: %s\n", UTF8(schemaError));
        return NO;
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&error];
    if (!data) {
        fprintf(stderr, "Glancebar: JSON encoding failed: %s\n", UTF8(error.localizedDescription));
        return NO;
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    return YES;
}

static void PrintUsage(FILE *stream) {
    fprintf(stream,
        "Glancebar %s\n"
        "Usage: Glancebar [--dump [--json] [--strict] [--online]]\n"
        "       Glancebar --version\n"
        "       Glancebar --help\n\n"
        "  --dump     Print a local machine and AI status snapshot.\n"
        "  --json     Emit stable JSON (schemaVersion 1) instead of text.\n"
        "  --strict   Exit 2 when any sampled source is partial/unavailable.\n"
        "  --online   Permit the already-opted-in Claude account request.\n",
        UTF8(GBVersion));
}

// Launching an app bundle's executable directly leaves the process anonymous to
// Launch Services. On macOS 26, Control Centre can then persistently file the app's
// status item under the terminal (or another parent app) and inherit that app's
// "Allow in the Menu Bar" setting. Relaunch before NSApplication creates any item.
// CLI modes return above and intentionally remain ordinary direct processes.
static int RelaunchGUIThroughLaunchServicesIfNeeded(BOOL alreadyRelaunched) {
    NSString *expected = NSBundle.mainBundle.bundleIdentifier;
    if (expected.length == 0) {
        fprintf(stderr, "Glancebar: app bundle has no identifier; refusing GUI launch\n");
        return 70;
    }

    NSString *running = NSRunningApplication.currentApplication.bundleIdentifier;
    if (!GUIRequiresLaunchServicesRelaunch(running, expected)) return -1;

    if (alreadyRelaunched) {
        fprintf(stderr, "Glancebar: Launch Services did not establish the app identity; refusing to relaunch again\n");
        return 70;
    }

    NSURL *bundleURL = NSBundle.mainBundle.bundleURL;
    if (![[bundleURL.pathExtension lowercaseString] isEqualToString:@"app"]) {
        fprintf(stderr, "Glancebar: GUI mode must be launched from Glancebar.app\n");
        return 70;
    }

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = @[bundleURL.path, @"--args", @"--glancebar-launch-services-relaunch"];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        fprintf(stderr, "Glancebar: could not relaunch through Launch Services: %s\n",
                UTF8(error.localizedDescription));
        return 70;
    }
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        fprintf(stderr, "Glancebar: Launch Services relaunch failed (%d)\n",
                task.terminationStatus);
        return 70;
    }
    return 0;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        BOOL dump = NO, json = NO, strict = NO, onlineArgument = NO, alreadyRelaunched = NO;
        const char *onlineEnvironment = getenv("GLANCEBAR_ALLOW_ACCOUNT");
        BOOL allowOnline = onlineEnvironment && strcmp(onlineEnvironment, "1") == 0;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--dump") == 0) dump = YES;
            else if (strcmp(argv[i], "--json") == 0) json = YES;
            else if (strcmp(argv[i], "--strict") == 0) strict = YES;
            else if (strcmp(argv[i], "--online") == 0) { allowOnline = YES; onlineArgument = YES; }
            else if (strcmp(argv[i], "--glancebar-launch-services-relaunch") == 0)
                alreadyRelaunched = YES;
            else if (strcmp(argv[i], "--version") == 0) { printf("Glancebar %s\n", UTF8(GBVersion)); return 0; }
            else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) { PrintUsage(stdout); return 0; }
            else { fprintf(stderr, "Glancebar: unknown option '%s'\n", argv[i]); PrintUsage(stderr); return 64; }
        }
        if ((json || strict || onlineArgument) && !dump) {
            fprintf(stderr, "Glancebar: --json, --strict, and --online require --dump\n");
            return 64;
        }
        if (dump) {
            NSDictionary *snapshot = DumpSnapshot(allowOnline);
            if (json) {
                if (!PrintJSONDump(snapshot)) return 70;
            } else PrintHumanDump(snapshot);
            return strict && [snapshot[@"status"] isEqualToString:@"partial"] ? 2 : 0;
        }
        int relaunchResult = RelaunchGUIThroughLaunchServicesIfNeeded(alreadyRelaunched);
        if (relaunchResult >= 0) return relaunchResult;
        NSApplication *app = NSApplication.sharedApplication;
        Controller *controller = [Controller new];
        app.delegate = controller;
        [app run];
    }
    return 0;
}
