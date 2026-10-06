// Glancebar — one configurable menu bar item at a glance. Click for a native popover
// with storage, battery, system, and AI summaries plus a deeper details window.
// Single-file Objective-C/AppKit. Zero dependencies, no sudo. Pure logic in pure.{h,m}.
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hidsystem/ev_keymap.h>
#import <IOKit/ps/IOPowerSources.h>
#import <Network/Network.h>
#import <ServiceManagement/ServiceManagement.h>
#import <libproc.h>
#import <mach/mach.h>
#import <signal.h>
#import <sys/mount.h>
#import <sys/sysctl.h>
#import <os/log.h>
#import "pure.h"
#import "nowplaying.h"

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
@property long long total, available, physicalAvailable;
@property BOOL isInternal;
@end
@implementation Volume
- (long long)used { return MAX(0LL, self.total - self.available); }
// Finder-style "available" counts purgeable data (caches, staged updates, local
// snapshots) as free; this is how much of that figure macOS would first have to thin.
- (long long)purgeable { return MAX(0LL, self.available - self.physicalAvailable); }
- (double)fraction { return self.total > 0 ? (double)self.used / self.total : 0; }
@end

static NSString *FmtBytes(long long b) {   // volumes: decimal, as Finder shows them
    return [NSByteCountFormatter stringFromByteCount:b countStyle:NSByteCountFormatterCountStyleFile];
}
static NSString *FmtMemBytes(long long b) {   // memory, swap, footprints: binary, as Activity Monitor and top show them
    return [NSByteCountFormatter stringFromByteCount:b countStyle:NSByteCountFormatterCountStyleMemory];
}

static Volume *VolumeFromURL(NSURL *url, NSArray *keys) {
    NSDictionary *v = [url resourceValuesForKeys:keys error:nil];
    NSNumber *total = v[NSURLVolumeTotalCapacityKey];
    NSString *name = v[NSURLVolumeNameKey];
    if (total.longLongValue <= 0) return nil;

    long long avail = [v[NSURLVolumeAvailableCapacityKey] longLongValue];
    // Important-usage rides in `keys` only for a local volume. A second query for it
    // stalls this serial queue when the mount is a hung network volume.
    NSNumber *important = v[NSURLVolumeAvailableCapacityForImportantUsageKey];
    // APFS reports purgeable space in the "important usage" figure, which can exceed
    // total capacity; clamp so used/free/fraction stay self-consistent.
    long long physical = MAX(0LL, MIN(avail, total.longLongValue));
    if (important.longLongValue > 0) avail = important.longLongValue;
    // Network and transient volumes can briefly report -1 or a free-space figure larger
    // than their capacity. Clamp every source, not just the APFS "important" value.
    avail = MAX(0LL, MIN(avail, total.longLongValue));

    Volume *vol = [Volume new];
    vol.path = url.path.length ? url.path : @"/";
    vol.name = name.length ? name : [NSFileManager.defaultManager displayNameAtPath:vol.path];
    if (!vol.name.length) vol.name = vol.path;
    vol.total = total.longLongValue; vol.available = avail;
    vol.physicalAvailable = MIN(physical, avail);
    vol.isInternal = [v[NSURLVolumeIsInternalKey] boolValue] || [vol.path isEqualToString:@"/"];
    return vol;
}

static Volume *RootVolumeFallback(void) {
    NSURL *root = [NSURL fileURLWithPath:@"/" isDirectory:YES];
    Volume *fromURL = VolumeFromURL(root, VolumeResourceKeys(YES));
    if (fromURL) return fromURL;

    struct statfs s;
    if (statfs("/", &s) != 0 || s.f_blocks <= 0) return nil;
    Volume *vol = [Volume new];
    vol.path = @"/";
    NSString *displayName = [NSFileManager.defaultManager displayNameAtPath:@"/"];
    vol.name = displayName.length ? displayName : @"Macintosh HD";
    vol.total = (long long)s.f_blocks * (long long)s.f_bsize;
    vol.available = (long long)s.f_bavail * (long long)s.f_bsize;
    vol.physicalAvailable = vol.available;
    vol.isInternal = YES;
    return vol;
}

static NSArray<Volume *> *ScanVolumes(void) {
    // Prefetch every key except important-usage. That one is added only after the
    // cached local flag says the mount is local — asking a network volume for it hangs.
    NSArray *enumKeys = VolumeResourceKeys(NO);
    NSArray<NSURL *> *urls = [NSFileManager.defaultManager
        mountedVolumeURLsIncludingResourceValuesForKeys:enumKeys
                                                options:NSVolumeEnumerationSkipHiddenVolumes];
    NSMutableArray<Volume *> *found = [NSMutableArray array];
    BOOL hasRoot = NO;
    for (NSURL *url in urls) {
        id localValue = nil;
        BOOL haveLocal = [url getResourceValue:&localValue forKey:NSURLVolumeIsLocalKey error:nil];
        BOOL isLocal = haveLocal && [localValue isKindOfClass:NSNumber.class] && [localValue boolValue];
        Volume *vol = VolumeFromURL(url, VolumeResourceKeys(isLocal));
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
    // Not inside a bundle: the executable path still names it better than `top`'s
    // command column does, which prints a bare version number for Claude Code.
    if (app.location == NSNotFound) return ProcessNameFromPath(p);
    NSString *bundle = [p substringToIndex:app.location + 4];
    NSString *name = [NSFileManager.defaultManager displayNameAtPath:bundle];
    if ([name hasSuffix:@".app"]) name = [name substringToIndex:name.length - 4];
    return name.length ? name : nil;
}

// SIGTERM a child after `seconds`, SIGKILL a second later, unless disarmed first. Callers
// disarm right after waitUntilExit, so a reaped child's recycled pid is never signalled.
@interface GBWatchdog : NSObject
- (instancetype)initWithPid:(pid_t)pid seconds:(int64_t)seconds;
- (void)disarm;
@end
@implementation GBWatchdog { pid_t _pid; BOOL _disarmed; }
- (instancetype)initWithPid:(pid_t)pid seconds:(int64_t)seconds {
    if (!(self = [super init])) return nil;
    _pid = pid;
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC), q, ^{
        [self signal:SIGTERM];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), q, ^{ [self signal:SIGKILL]; });
    });
    return self;
}
- (void)signal:(int)sig { @synchronized (self) { if (!_disarmed) kill(_pid, sig); } }
- (void)disarm { @synchronized (self) { _disarmed = YES; } }
@end

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
    // Signal by pid (NSTask is not thread-safe), and judge the outcome by how the child
    // ended rather than by a flag shared across queues: a killed child is never a success.
    GBWatchdog *watchdog = [[GBWatchdog alloc] initWithPid:t.processIdentifier seconds:8];
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    [watchdog disarm];
    if (t.terminationReason != NSTaskTerminationReasonExit || t.terminationStatus != 0) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// Reads the live SleepDisabled system power setting (no admin needed — a plain IOKit read
// surfaced by `pmset -g`). YES = Keep Awake is on (no idle or lid-close sleep).
// nil when the setting could not be read — callers must not mistake that for "normal
// sleep", or the toggle would offer to ENABLE staying awake on a Mac that already is.
static NSNumber *SleepDisabledStateViaTool(void) {
    NSString *out = RunTaskOutput(@"/usr/bin/pmset", @[@"-g"]);
    return out.length ? ParseSleepDisabled(out) : nil;
}
// The system power plist is world-readable and carries the same key pmset prints, in a
// few milliseconds and with no child process — safe on the main thread. pmset is the
// fallback for a plist that has never had the key written.
static NSNumber *SleepDisabledState(void) {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:@"/Library/Preferences/com.apple.PowerManagement.plist"];
    NSDictionary *settings = [plist[@"SystemPowerSettings"] isKindOfClass:NSDictionary.class]
        ? plist[@"SystemPowerSettings"] : nil;
    id value = settings[@"SleepDisabled"];
    if ([value isKindOfClass:NSNumber.class]) return @([value boolValue]);
    return SleepDisabledStateViaTool();
}

// Runs a root shell command through an osascript administrator prompt: macOS
// shows its own authentication dialog and runs pmset as root just this once — no background
// helper or LaunchDaemon is installed. Returns YES only if the change was applied (NO when
// the user cancels the prompt or authorization fails). Commands and prompts are built only
// from fixed literals (plus a validated user name) — never free input — and contain no
// double quote or backslash, so nothing can break out of the AppleScript string.
static BOOL SetPmsetShellViaAdmin(NSString *shell, NSString *prompt) {
    NSString *script = [NSString stringWithFormat:
        @"do shell script \"%@\" with prompt \"%@\" with administrator privileges", shell, prompt];
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    t.arguments = @[@"-e", script];
    t.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![t launchAndReturnError:NULL]) return NO;
    [t waitUntilExit];
    return t.terminationStatus == 0;
}
// Low Power Mode as the system is applying it right now (a plain in-process read, main-thread
// safe). `-a` sets it for battery and adapter alike, so an "only on battery" choice made in
// System Settings becomes plain on/off once toggled here.
static BOOL LowPowerModeEnabled(void) { return NSProcessInfo.processInfo.lowPowerModeEnabled; }

// One-click pmset toggles. macOS's admin prompt only takes a typed password, so the fast
// path is a one-time sudoers rule (PmsetSudoersRule: exactly four pmset commands). The
// rule is the security boundary, and the worst it permits is toggling Low Power Mode or
// lid-close sleep. A Touch ID check in front of it guarded nothing (any process of this
// user can run the same `sudo -n`), so the switches no longer ask (2026-10-06).
static NSString *const kPmsetSudoersPath = @"/etc/sudoers.d/glancebar";
static BOOL PmsetRuleInstalled(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:kPmsetSudoersPath];
}
static BOOL RunPmsetViaSudo(NSString *setting, BOOL enable) {
    return RunTaskOutput(@"/usr/bin/sudo", @[@"-n", @"/usr/bin/pmset", @"-a", setting, enable ? @"1" : @"0"]) != nil;
}
// Writes the rule from inside the root shell (never from a user-writable temp file a
// same-user process could swap before root reads it), checks it with visudo, then moves
// it into place; a rule that fails visudo never lands. The rule text is fixed apart from
// a user name PmsetSudoersRule has restricted to [A-Za-z0-9_.-].
static BOOL InstallPmsetRule(void) {
    NSString *rule = PmsetSudoersRule(NSUserName());
    if (!rule) return NO;
    NSString *shell = [NSString stringWithFormat:
        @"umask 377; f=/etc/sudoers.d/.glancebar-new; /bin/rm -f $f; "
        @"{ echo '# Installed by Glancebar for one-click power toggles. Delete this file to revoke.'; echo '%@'; } > $f "
        @"&& /usr/sbin/visudo -cqf $f && /bin/chmod 0440 $f && /usr/sbin/chown root:wheel $f "
        @"&& /bin/mv -f $f %@ || { /bin/rm -f $f; exit 1; }", rule, kPmsetSudoersPath];
    return SetPmsetShellViaAdmin(shell, @"Glancebar needs your password once so Keep Awake and Low Power can switch without asking again.");
}
static BOOL RemovePmsetRule(void) {
    return SetPmsetShellViaAdmin([@"/bin/rm -f " stringByAppendingString:kPmsetSudoersPath],
                                 @"Glancebar needs administrator access to remove its power-switch rule.");
}

static NSArray<NSDictionary *> *SampleHogs(int topN) {
    NSString *out = RunTaskOutput(@"/usr/bin/top", @[@"-l", @"2", @"-s", @"1", @"-stats",
                                                     @"pid,command,power", @"-o", @"power", @"-n", @"40"]);
    // The sampler's own `top` scores itself (12% of an idle sample on 2026-09-07). It is
    // measurement, not a hog; drop it and let the next real row up.
    NSArray<NSDictionary *> *rows = ParseHogs(out ? out : @"", topN + 1,
                                              ^NSString *(pid_t pid){ return AppGroupForPid(pid); });
    NSMutableArray *kept = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSArray *commands = [row[@"commands"] isKindOfClass:NSArray.class] ? row[@"commands"] : @[];
        if ([row[@"name"] isEqual:@"top"] && commands.count == 1 && [commands.firstObject isEqual:@"top"]) continue;
        if ((int)kept.count >= topN) break;
        [kept addObject:row];
    }
    return kept;
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
            // Activity Monitor's "Memory Used": app memory (anonymous pages less the
            // purgeable ones) + wired + compressed. Counting every active page instead
            // read 3.5 GB low on 2026-09-07; inactive anonymous pages are still in use.
            uint64_t anonymous = vm.internal_page_count > vm.purgeable_count
                ? (uint64_t)vm.internal_page_count - vm.purgeable_count : 0;
            uint64_t usedPages = anonymous + vm.wire_count + vm.compressor_page_count;
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
            MemoryPressureLevel(s), FmtMemBytes(s.memAvailable)];
}

static NSString *SwapStatusText(SystemState s) {
    if (!s.swapValid) return @"Swap unknown";
    if (s.swapUsed == 0) return @"Swap none";   // NSByteCountFormatter renders 0 as "Zero KB"
    return [NSString stringWithFormat:@"Swap %@", FmtMemBytes(s.swapUsed)];
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
@property (copy) NSString *billingNote;   // Codex: where requests bill when not the shown window's bucket
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
static const double kHiddenAIRefreshInterval = 300;   // background pass while no AI surface shows
static const double kAuthFailureRetryInterval = 300;  // after a 401/403: a re-login is quick

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
    // A dated override is a statement about one window. Once that window has reset the
    // file is stale, and the provider's own figure is the truth again.
    if (resetDate && resetDate.timeIntervalSinceNow <= 0) return;
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
static NSString *KeychainBlobViaSecurity(NSString *service, NSString *account) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/security"];
    t.arguments = @[@"find-generic-password", @"-w", @"-s", service, @"-a", account.length ? account : NSUserName()];
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *pipe = [NSPipe pipe]; t.standardOutput = pipe;
    if (![t launchAndReturnError:nil]) return nil;

    // `security` normally returns instantly; if it ever wedges, terminate at 5s and
    // force-kill at 6s. Without the kill, a child that ignores SIGTERM leaves the read
    // below blocked forever and wedges the serial AI queue with it.
    GBWatchdog *watchdog = [[GBWatchdog alloc] initWithPid:t.processIdentifier seconds:5];
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];   // unblocks on exit/terminate
    [t waitUntilExit];
    [watchdog disarm];
    if (t.terminationReason != NSTaskTerminationReasonExit || t.terminationStatus != 0 || data.length == 0 || data.length > 64 * 1024) return nil;

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
    NSString *blob = KeychainBlobViaSecurity(@"Claude Code-credentials", nil);
    if (!blob.length) return nil;
    NSData *data = [blob dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *oauth = [json[@"claudeAiOauth"] isKindOfClass:NSDictionary.class] ? json[@"claudeAiOauth"] : nil;
    if (!oauth) return nil;
    NSString *token = [oauth[@"accessToken"] isKindOfClass:NSString.class] ? oauth[@"accessToken"] : nil;
    double expiresAt = [oauth[@"expiresAt"] doubleValue] / 1000.0;   // ms epoch
    return @{@"token": token ?: @"", @"expiresAt": @(expiresAt)};    // expiry judged by the caller
}

// Authorization headers must never follow a provider-controlled redirect. A same-host
// HTTPS redirect is acceptable; every other destination is refused.
@interface GBPinnedHostSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@property (copy) NSString *host;
@end
@implementation GBPinnedHostSessionDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
        willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                         newRequest:(NSURLRequest *)request
                  completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    NSURL *url = request.URL;
    BOOL sameTrustedHost = [url.scheme.lowercaseString isEqualToString:@"https"] &&
                           [url.host.lowercaseString isEqualToString:self.host];
    completionHandler(sameTrustedHost ? request : nil);
}
@end

static NSDictionary *FetchResult(NSData *data, NSHTTPURLResponse *http, NSError *err, NSString *fallbackMessage);
static NSDictionary *HTTPJSON(NSString *token, NSString *method, NSString *urlString, NSString *host,
                              NSDictionary *headers, NSData *body, NSString *timeoutMessage);

// One GET to Anthropic's OAuth usage endpoint — the same data Claude Code's /usage
// shows. Synchronous by design: callers run on the AI queue, never the main thread.
static NSDictionary *FetchClaudeUsageJSON(NSString *token) {
    return HTTPJSON(token, @"GET", @"https://api.anthropic.com/api/oauth/usage", @"api.anthropic.com",
                    @{@"anthropic-beta": @"oauth-2025-04-20"}, nil, @"Claude usage API request timed out");
}

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

// The Cursor CLI (`agent`) keeps its own session in the Keychain, written through
// /usr/bin/security, so the same Apple-tool read is silent. Someone who only uses the CLI
// never refreshes the desktop app's state.vscdb token, which then expires and 401s
// (2026-10-04); taking the freshest of the two keeps either kind of user signed in.
// Only the real home has a Keychain session: a fixture home must never see it.
static NSString *CursorSessionToken(NSString *homeDirectory, NSString *rejected) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSString *home = homeDirectory.length ? homeDirectory.stringByStandardizingPath : GBHomeDirectory();
    if ([home isEqualToString:GBHomeDirectory().stringByStandardizingPath]) {
        NSString *cli = KeychainBlobViaSecurity(@"cursor-access-token", @"cursor-user");
        if (cli.length && cli.length < 8192) [tokens addObject:cli];
    }
    NSString *app = CursorAccessTokenFromStateDB(homeDirectory);
    if (app.length) [tokens addObject:app];
    // A token the server just refused is passed over, so a shorter-lived live session in
    // the other client still gets its turn.
    if (rejected.length && tokens.count > 1) [tokens removeObject:rejected];
    // All expired: hand back one anyway so the caller can say "signed out" precisely.
    return FreshestSessionToken(tokens, NSDate.date.timeIntervalSince1970, NULL) ?: tokens.firstObject;
}

static NSDictionary *FetchResult(NSData *data, NSHTTPURLResponse *http, NSError *err,
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

// One bounded JSON request with a bearer token, pinned to `host` across redirects.
// Synchronous by design: callers run on the AI queue, never the main thread.
static NSDictionary *HTTPJSON(NSString *token, NSString *method, NSString *urlString, NSString *host,
                              NSDictionary *headers, NSData *body, NSString *timeoutMessage) {
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
    GBPinnedHostSessionDelegate *delegate = [GBPinnedHostSessionDelegate new];
    delegate.host = host;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:delegate delegateQueue:nil];

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *json = nil;
    __block BOOL completed = NO;
    [[session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)resp : nil;
            json = FetchResult(data, http, err, timeoutMessage);
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
                 @"message": timeoutMessage};
    }
    return json;
}

// Prefer GetCurrentPeriodUsage (Pro/Team included spend). Fall back to legacy /auth/usage
// request buckets when the dashboard response has no usable planUsage window.
static NSDictionary *FetchCursorUsageJSON(NSString *token) {
    double now = NSDate.date.timeIntervalSince1970;
    NSData *emptyBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *period = HTTPJSON(
        token, @"POST",
        @"https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage", @"api2.cursor.sh",
        @{@"Content-Type": @"application/json", @"Connect-Protocol-Version": @"1"},
        emptyBody, @"Cursor usage API request timed out");
    if (![period[@"_glancebarFetchError"] boolValue] && PickCursorLimitWindow(period, now))
        return period;
    // A rejected token is rejected everywhere; a second request only doubles the noise.
    if (ShouldDropCachedTokenForStatus([period[@"statusCode"] integerValue])) return period;
    // An ended billing cycle is still the plan's answer; legacy request buckets would
    // pass it off as leftover quota.
    if (![period[@"_glancebarFetchError"] boolValue] && CursorStaleLimitWindows(period, now).count) return period;

    NSDictionary *auth = HTTPJSON(token, @"GET", @"https://api2.cursor.sh/auth/usage", @"api2.cursor.sh",
                                  nil, nil, @"Cursor usage API request timed out");
    if (![auth[@"_glancebarFetchError"] boolValue] && PickCursorLimitWindow(auth, now))
        return auth;
    // A 401 from either call means sign in again, whatever the other one said.
    if (ShouldDropCachedTokenForStatus([auth[@"statusCode"] integerValue])) return auth;
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
// Seams for the parts that touch the Keychain, Cursor's state DB and the network,
// so the whole account path can run in a test without any of them. Defaults are the
// real readers/fetchers; replace them before the first read.
@property (copy) NSDictionary *(^claudeCredentialReader)(void);          // @{token, expiresAt} or nil
@property (copy) NSDictionary *(^claudeUsageFetcher)(NSString *token);
@property (copy) NSString *(^cursorTokenReader)(NSString *homeDirectory);
@property (copy) NSString *cursorRejectedToken;   // last token a Cursor endpoint refused
@property (copy) NSDictionary *(^cursorUsageFetcher)(NSString *token);
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
- (void)purgeClaudeTranscriptIndex;
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
    NSMutableDictionary<NSString *, NSDictionary *> *_days;  // local "yyyy-MM-dd" -> @{@"t":, @"f":, ...}
    // Best known meters per limit_id — see FoldCodexSnapshotIntoBuckets. Buckets are
    // compared, never blended: on 2026-09-07 a blend read "100% left" off an untouched
    // side bucket while the plan bucket sat at 99% used.
    NSDictionary *_buckets;
    NSString *_limitsTs;            // newest snapshot's timestamp across buckets
    // The newest snapshot verbatim. A bucket is a deliberate merge of its best-known
    // meters, so asking IT whether Codex still speaks a shape we understand answers the
    // wrong question: one carried-forward window makes any merge look readable.
    NSDictionary *_limitsNewest;
    NSDate *_dbStamp;               // change detection for the sqlite extras
    NSString *_dbDay;
    long long _sessionsToday, _sessionsWeek;
    NSArray<NSDictionary *> *_models;
    NSDate *_lastActivity;
    NSMutableDictionary<NSString *, NSDictionary *> *_claudeDays;
    // Derived from the transcript index, not the stats cache (which Claude Code stopped
    // writing in June 2026): 7-day fresh tokens per model, sessions, messages, tool calls.
    NSArray<NSDictionary *> *_claudeModels;
    long long _claudeSessionsToday, _claudeSessionsWeek, _claudeMessagesToday, _claudeToolsToday;
    NSDate *_claudeLastActivity;
    NSDictionary *_claudeUsageJSON;             // last good OAuth usage response
    double _claudeNextFetch;                    // epoch; throttles the usage endpoint
    NSUInteger _claudeRateLimitStreak;          // consecutive 429s; drives the blind backoff
    NSUInteger _cursorRateLimitStreak;
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
    NSString *_claudeFetchSkipReason, *_cursorFetchSkipReason;
    BOOL _claudeStatuslineLogged;
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
    NSDate *_stateFileSeen;    // mtime of the state file as last read or written by us
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
        _claudeCredentialReader = ^NSDictionary *{ return ClaudeAccessTokenFromKeychain(); };
        _claudeUsageFetcher = ^NSDictionary *(NSString *token){ return FetchClaudeUsageJSON(token); };
        __weak AIReader *weakSelf = self;
        _cursorTokenReader = ^NSString *(NSString *home){ return CursorSessionToken(home, weakSelf.cursorRejectedToken); };
        _cursorUsageFetcher = ^NSDictionary *(NSString *token){ return FetchCursorUsageJSON(token); };
        [self loadPersistentState];
    }
    return self;
}

// The GUI and `--dump --online` share one state file, and each process holds its own
// copy of the account responses. Whenever the file has changed under us, adopt any
// FRESHER account response it carries instead of overwriting it with our older one on
// the next save — the CLI's fetch then shows in the running app within a tick.
- (void)adoptNewerAccountCachesFromDisk {
    NSDate *mtime = FileMTime(_statePath);
    if (!mtime || (_stateFileSeen && [mtime compare:_stateFileSeen] != NSOrderedDescending)) return;
    _stateFileSeen = mtime;
    NSDictionary *root = JSONDictionaryAtPath(_statePath);
    if ([root[@"version"] integerValue] != 2) return;
    NSDictionary *claude = [root[@"claudeUsageJSON"] isKindOfClass:NSDictionary.class] ? root[@"claudeUsageJSON"] : nil;
    NSDate *claudeAt = DateFromStatusString([root[@"claudeUsageFetchedAt"] isKindOfClass:NSString.class] ? root[@"claudeUsageFetchedAt"] : nil);
    if (self.useClaudeAccount && claude && claudeAt && claudeAt.timeIntervalSince1970 > _claudeLastSuccessAt + 1) {
        _claudeUsageJSON = claude;
        _claudeLastSuccessAt = claudeAt.timeIntervalSince1970;
        _claudeNextFetch = MAX(_claudeNextFetch, _claudeLastSuccessAt + kAccountPollInterval);
        _claudeAccountStatus = nil;
        _claudeUsageCacheAbandoned = NO;
        GBLog("claude cache: adopted a newer on-disk response");
    }
    NSDictionary *cursor = [root[@"cursorUsageJSON"] isKindOfClass:NSDictionary.class] ? root[@"cursorUsageJSON"] : nil;
    NSDate *cursorAt = DateFromStatusString([root[@"cursorUsageFetchedAt"] isKindOfClass:NSString.class] ? root[@"cursorUsageFetchedAt"] : nil);
    if (self.useCursorAccount && cursor && cursorAt && cursorAt.timeIntervalSince1970 > _cursorLastSuccessAt + 1) {
        _cursorUsageJSON = cursor;
        _cursorLastSuccessAt = cursorAt.timeIntervalSince1970;
        _cursorNextFetch = MAX(_cursorNextFetch, _cursorLastSuccessAt + kAccountPollInterval);
        _cursorAccountStatus = nil;
        _cursorUsageCacheAbandoned = NO;
        GBLog("cursor cache: adopted a newer on-disk response");
    }
}

- (void)loadPersistentState {
    _stateFileSeen = FileMTime(_statePath);
    NSData *data = [NSData dataWithContentsOfFile:_statePath options:0 error:nil];
    NSDictionary *root = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![root isKindOfClass:NSDictionary.class] || [root[@"version"] integerValue] != 2) return;
    NSString *timeZone = [root[@"timeZone"] isKindOfClass:NSString.class] ? root[@"timeZone"] : nil;
    // Day totals were bucketed in the zone the index was built in. Rebuilding them for a
    // new zone means re-reading the corpus (15 GB of Codex rollouts in the 8-day window),
    // which is far worse than day boundaries a few hours off for a week of travel. Keep
    // the index; new events bucket in the current zone and the old days age out.
    if (timeZone.length && ![timeZone isEqualToString:NSTimeZone.localTimeZone.name])
        GBLog("state: time zone changed since the index was built; keeping it");
    NSDictionary *codex = [root[@"codexFiles"] isKindOfClass:NSDictionary.class] ? root[@"codexFiles"] : nil;
    NSDictionary *claude = [root[@"claudeFiles"] isKindOfClass:NSDictionary.class] ? root[@"claudeFiles"] : nil;
    for (NSString *key in codex) {
        NSDictionary *record = [codex[key] isKindOfClass:NSDictionary.class] ? codex[key] : nil;
        if (key.length && record) _codexFiles[key] = [record mutableCopy];
    }
    for (NSString *key in claude) {
        NSDictionary *record = [claude[key] isKindOfClass:NSDictionary.class] ? claude[key] : nil;
        if (key.length && record) _claudeFiles[key] = [self upgradedClaudeRecord:[record mutableCopy]];
    }
    // Records written before limit buckets existed carry `latestLimits`, a blend across
    // every limit_id the file saw, filed under whichever id reported last. Re-reading
    // 15 GB of rollouts is not an option; instead the blend is ignored and the newest
    // files are re-peeked (tailSize cleared) so the current picture returns at once.
    for (NSMutableDictionary *record in _codexFiles.allValues) {
        if (record[@"latestLimits"] || record[@"peekLimits"]) {
            [record removeObjectForKey:@"latestLimits"];
            [record removeObjectForKey:@"latestTs"];
            [record removeObjectForKey:@"peekLimits"];
            [record removeObjectForKey:@"peekTs"];
            [record removeObjectForKey:@"tailSize"];
            _stateDirty = YES;
        }
    }
    NSDictionary *buckets = [root[@"codexBuckets"] isKindOfClass:NSDictionary.class] ? root[@"codexBuckets"] : nil;
    if (buckets.count) {
        _buckets = buckets;
        _limitsTs = BucketsNewestTs(buckets);
        _limitsNewest = CodexNewestBucketLimits(buckets);
    }
    NSDictionary *claudeUsage = [root[@"claudeUsageJSON"] isKindOfClass:NSDictionary.class]
        ? root[@"claudeUsageJSON"] : nil;
    if (claudeUsage) {
        _claudeUsageJSON = claudeUsage;
        NSString *fetched = [root[@"claudeUsageFetchedAt"] isKindOfClass:NSString.class]
            ? root[@"claudeUsageFetchedAt"] : nil;
        NSDate *when = DateFromStatusString(fetched);
        if (when) _claudeLastSuccessAt = when.timeIntervalSince1970;
        // The throttle survives restarts and --dump runs: a figure younger than the poll
        // interval is as current as a fresh fetch would make it, and the endpoint rate-limits.
        if (when) _claudeNextFetch = _claudeLastSuccessAt + kAccountPollInterval;
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
        if (when) _cursorNextFetch = _cursorLastSuccessAt + kAccountPollInterval;
        _cursorFetchedThisRun = NO;
        _cursorUsageCacheAbandoned = NO;
    }
}

static NSString *BucketsNewestTs(NSDictionary *buckets) {
    NSString *newest = CodexNewestBucketID(buckets);
    NSDictionary *entry = newest ? buckets[newest] : nil;
    return [entry[@"ts"] isKindOfClass:NSString.class] ? entry[@"ts"] : nil;
}

// A transcript record indexed before per-model/activity counters existed knows only
// day totals. The 8-day window it can still contribute to is re-read from offset 0 (a
// few hundred MB at most, reported as "Indexing transcripts N%"); identity is kept so
// the file is not mistaken for a new one.
static const NSInteger kClaudeRecordSchema = 2;
- (NSMutableDictionary *)upgradedClaudeRecord:(NSMutableDictionary *)record {
    if ([record[@"v"] integerValue] >= kClaudeRecordSchema) return record;
    NSMutableDictionary *fresh = [NSMutableDictionary dictionaryWithObject:@0 forKey:@"offset"];
    if (record[@"dev"]) fresh[@"dev"] = record[@"dev"];
    if (record[@"ino"]) fresh[@"ino"] = record[@"ino"];
    fresh[@"v"] = @(kClaudeRecordSchema);
    _stateDirty = YES;
    return fresh;
}

// Indexing a large backlog drives read() in a tight catch-up loop, and each pass rewrote the
// whole (growing) state file. Coalesce those writes: during catch-up a lost write only costs
// a re-read of the last couple of seconds' bytes, since offsets and totals move together.
// The pass that finishes the backlog always writes, so a settled index is never stale.
static const double kAIStateWriteInterval = 2.0;

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
    if (_buckets.count) root[@"codexBuckets"] = _buckets;
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
    _stateFileSeen = FileMTime(_statePath);
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
    for (NSString *field in @[@"dev", @"ino", @"size", @"mtime", @"sub"]) {
        if ([field isEqualToString:@"size"] && [record[@"inventoryMismatch"] boolValue]) continue;
        id value = candidate[field];
        if (value && ![record[field] isEqual:value]) { record[field] = value; _stateDirty = YES; }
    }
    if (!record[@"offset"]) record[@"offset"] = @0;
    if (files == _claudeFiles && !record[@"v"]) { record[@"v"] = @(kClaudeRecordSchema); _stateDirty = YES; }
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
        // Subagent transcripts spend tokens like any other, but they are not sessions the
        // user started; the flag (never the path) lets the session count skip them.
        if ([rel.pathComponents containsObject:@"subagents"]) candidate[@"sub"] = @YES;
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
        NSDictionary *add = [days[day] isKindOfClass:NSDictionary.class] ? days[day] : nil;
        if (!add) continue;
        sum[day] = MergeDayCounts(sum[day], add);
    }
}

- (void)rebuildCodexDerivedState {
    NSString *weekStart = WeekStartDayString();
    NSMutableDictionary *sum = [NSMutableDictionary dictionary];
    NSDictionary *buckets = nil, *newestLimits = nil;
    NSString *newestTs = nil;
    for (NSMutableDictionary *record in _codexFiles.allValues) {
        NSMutableDictionary *recordDays = [([record[@"days"] isKindOfClass:NSDictionary.class]
                                             ? record[@"days"] : @{}) mutableCopy];
        NSUInteger before = recordDays.count;
        PruneDays(recordDays, weekStart);
        if (recordDays.count != before) { record[@"days"] = recordDays; _stateDirty = YES; }
        AddDays(sum, recordDays);
        // Bucket-wise and meter-wise, not snapshot-wise: once an allowance is spent Codex
        // stops sending its windows, so the newest snapshot alone knows least — and it
        // may belong to a different bucket altogether.
        for (NSString *prefix in @[@"latest", @"peek"]) {
            NSDictionary *recordBuckets = record[[prefix stringByAppendingString:@"Buckets"]];
            if ([recordBuckets isKindOfClass:NSDictionary.class] && recordBuckets.count)
                buckets = MergeCodexLimitBuckets(buckets, recordBuckets);
            NSString *ts = record[[prefix stringByAppendingString:@"NewestTs"]];
            NSDictionary *limits = record[[prefix stringByAppendingString:@"Newest"]];
            if ([limits isKindOfClass:NSDictionary.class] && [ts isKindOfClass:NSString.class] && ts.length &&
                (!newestTs || [ts compare:newestTs] == NSOrderedDescending)) {
                newestTs = ts;
                newestLimits = limits;   // verbatim, for the drift check
            }
        }
    }
    _days = sum;
    _buckets = buckets;
    _limitsTs = newestTs ?: BucketsNewestTs(buckets);
    _limitsNewest = newestLimits ?: CodexNewestBucketLimits(buckets);
}

- (void)rebuildClaudeDerivedState {
    NSString *weekStart = WeekStartDayString();
    NSString *today = LocalDateString(NSDate.date);
    NSMutableDictionary *sum = [NSMutableDictionary dictionary];
    long long sessionsToday = 0, sessionsWeek = 0;
    NSString *lastTs = nil;
    for (NSMutableDictionary *record in _claudeFiles.allValues) {
        NSMutableDictionary *recordDays = [([record[@"days"] isKindOfClass:NSDictionary.class]
                                             ? record[@"days"] : @{}) mutableCopy];
        NSUInteger before = recordDays.count;
        PruneDays(recordDays, weekStart);
        if (recordDays.count != before) { record[@"days"] = recordDays; _stateDirty = YES; }
        AddDays(sum, recordDays);
        // One transcript file is one session the user started; subagent transcripts are
        // not. A session counts on every local day it produced a message.
        if (![record[@"sub"] boolValue]) {
            BOOL anyDay = NO;
            for (NSString *day in recordDays) {
                if ([recordDays[day][@"n"] longLongValue] <= 0) continue;
                anyDay = YES;
                if ([day isEqualToString:today]) sessionsToday++;
            }
            if (anyDay) sessionsWeek++;
        }
        NSString *ts = [record[@"lastTs"] isKindOfClass:NSString.class] ? record[@"lastTs"] : nil;
        if (ts.length && (!lastTs || [ts compare:lastTs] == NSOrderedDescending)) lastTs = ts;
    }
    _claudeDays = sum;
    _claudeSessionsToday = sessionsToday;
    _claudeSessionsWeek = sessionsWeek;
    _claudeMessagesToday = [sum[today][@"n"] longLongValue];
    _claudeToolsToday = [sum[today][@"c"] longLongValue];
    _claudeLastActivity = lastTs ? DateFromStatusString(lastTs) : nil;
    NSMutableDictionary *models = [NSMutableDictionary dictionary];
    for (NSDictionary *day in sum.allValues) {
        NSDictionary *byModel = [day[@"m"] isKindOfClass:NSDictionary.class] ? day[@"m"] : nil;
        for (NSString *model in byModel)
            models[model] = @([models[model] longLongValue] + [byModel[model] longLongValue]);
    }
    _claudeModels = ModelRowsFromTokenDictionary(models);
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
    if ([acc[@"buckets"] isKindOfClass:NSDictionary.class]) {
        NSDictionary *merged = MergeCodexLimitBuckets(record[@"latestBuckets"], acc[@"buckets"]);
        if (merged.count) record[@"latestBuckets"] = merged;
        NSString *ts = acc[@"newestTs"];
        NSString *keptTs = [record[@"latestNewestTs"] isKindOfClass:NSString.class] ? record[@"latestNewestTs"] : nil;
        if (ts.length && acc[@"newestLimits"] && (!keptTs || [ts compare:keptTs] == NSOrderedDescending)) {
            record[@"latestNewest"] = acc[@"newestLimits"];
            record[@"latestNewestTs"] = ts;
        }
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
    // One message arrives as several lines sharing its message.id — one per content
    // block — and the usage on the early lines is a running figure (output_tokens 1–7)
    // that only the last line completes. Keeping the first line lost about 40% of the
    // fresh output tokens (2026-09-07 audit). So remember what has been counted for each
    // id and apply only the growth; every line's content blocks are new, so tool calls
    // simply add up. Hashes are compact and carry neither content nor the provider id.
    NSMutableDictionary *counted = [([record[@"idv"] isKindOfClass:NSDictionary.class] ? record[@"idv"] : @{}) mutableCopy];
    NSMutableArray *events = [NSMutableArray array];
    ForEachMatchingLine(chunk, "\"usage\"", ^(NSString *line) {
        NSDictionary *event = ParseClaudeUsageLine(line);
        if (!event) return;
        NSString *messageID = [event[@"id"] isKindOfClass:NSString.class] ? event[@"id"] : nil;
        if (!messageID.length) { [events addObject:event]; return; }
        NSString *hashed = HashedMessageID(messageID);
        long long fresh = [event[@"fresh"] longLongValue], tokens = [event[@"tokens"] longLongValue];
        NSArray *prev = [counted[hashed] isKindOfClass:NSArray.class] ? counted[hashed] : nil;
        if (prev.count < 2) {
            counted[hashed] = @[@(fresh), @(tokens)];
            [events addObject:event];
            return;
        }
        long long prevFresh = [prev[0] longLongValue], prevTokens = [prev[1] longLongValue];
        NSMutableDictionary *amend = [event mutableCopy];
        amend[@"amend"] = @YES;
        amend[@"fresh"] = @(MAX(0LL, fresh - prevFresh));
        amend[@"tokens"] = @(MAX(0LL, tokens - prevTokens));
        if (fresh > prevFresh || tokens > prevTokens)
            counted[hashed] = @[@(MAX(fresh, prevFresh)), @(MAX(tokens, prevTokens))];
        if ([amend[@"fresh"] longLongValue] > 0 || [amend[@"tokens"] longLongValue] > 0 ||
            [event[@"tools"] longLongValue] > 0)
            [events addObject:amend];
    });
    // Keep the per-id readings for the record's whole seven-day lifetime: a small rolling
    // window would double-count an older message amended much later.
    record[@"idv"] = counted;
    [record removeObjectForKey:@"ids"];
    if (events.count) {
        record[@"days"] = AccumulateTokenEvents(record[@"days"], events, nil)[@"days"] ?: @{};
        NSString *lastTs = [record[@"lastTs"] isKindOfClass:NSString.class] ? record[@"lastTs"] : nil;
        for (NSDictionary *event in events) {
            NSString *ts = event[@"ts"];
            if (ts.length && (!lastTs || [ts compare:lastTs] == NSOrderedDescending)) lastTs = ts;
        }
        if (lastTs.length) record[@"lastTs"] = lastTs;
    }
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
        __block NSDictionary *buckets = nil, *newest = nil;
        __block NSString *newestTs = nil;
        ForEachMatchingLine(tail, "\"token_count\"", ^(NSString *line) {
            NSDictionary *event = ParseTokenCountLine(line);
            NSString *ts = [event[@"ts"] isKindOfClass:NSString.class] ? event[@"ts"] : nil;
            NSDictionary *limits = [event[@"limits"] isKindOfClass:NSDictionary.class] ? event[@"limits"] : nil;
            if (limits && ts.length) {
                buckets = FoldCodexSnapshotIntoBuckets(buckets, limits, ts);
                if (!newestTs || [ts compare:newestTs] == NSOrderedDescending) { newestTs = ts; newest = limits; }
            }
        });
        if (buckets.count) {
            record[@"peekBuckets"] = buckets;
            record[@"peekNewest"] = newest;
            record[@"peekNewestTs"] = newestTs;
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
    NSDictionary *cred = self.claudeCredentialReader();
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

// Shared by both accounts. Pointers address the provider's own ivars, so each keeps its
// state (and the tests' KVC keys) exactly as before.
- (void)rememberFetchError:(NSDictionary *)fetch now:(double)now
                     token:(NSString *__strong *)token expiresAt:(double *)expiresAt
                 nextFetch:(double *)nextFetch status:(NSString *__strong *)status
           rateLimitStreak:(NSUInteger *)streak client:(NSString *)client {
    BOOL rateLimited = [fetch[@"rateLimited"] boolValue];
    double retry = [fetch[@"retryAfter"] doubleValue];
    NSString *message = [fetch[@"message"] isKindOfClass:NSString.class] ? fetch[@"message"] : nil;
    if (ShouldDropCachedTokenForStatus([fetch[@"statusCode"] integerValue])) {
        *token = nil;   // revoked; re-read the credential next attempt
        if (expiresAt) *expiresAt = 0;
        *nextFetch = MIN(*nextFetch, now + kAuthFailureRetryInterval);
    }
    if (rateLimited) {
        *streak += 1;
        *nextFetch = now + RateLimitRetryDelay(retry, *streak);
        *status = @"Usage API rate-limited; retrying shortly";
    } else {
        *streak = 0;
        *status = AccountFetchFailureStatus([fetch[@"statusCode"] integerValue], message, client);
    }
}

// The usage endpoint 429s readily and every other poller of it (a statusline, a budget
// script) shares the account's allowance. When Claude Code has written its own figures in
// the last few minutes, use them and push our next request back: fresher, and no request.
- (void)adoptClaudeStatuslineCacheAt:(double)now {
    NSString *path = [_homeDirectory stringByAppendingPathComponent:@".claude/.cache/rate-limits.json"];
    NSDate *mtime = FileMTime(path);
    if (!mtime || now - mtime.timeIntervalSince1970 > kAccountPollInterval) return;
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *cache = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![cache isKindOfClass:NSDictionary.class]) return;
    double fetchedAt = [cache[@"fetchedAt"] doubleValue] / 1000.0;   // ms epoch
    if (fetchedAt <= _claudeLastSuccessAt + 1 || fetchedAt > now + 60 || now - fetchedAt > kAccountPollInterval) return;
    NSDictionary *merged = ClaudeUsageOverlayingStatusline(_claudeUsageJSON, cache);
    if (!merged) return;
    _claudeUsageJSON = merged;
    _claudeLastSuccessAt = fetchedAt;
    _claudeNextFetch = MAX(_claudeNextFetch, fetchedAt + kAccountPollInterval);
    _claudeAccountStatus = nil;
    _claudeRateLimitStreak = 0;
    _claudeFetchedThisRun = YES;
    _claudeUsageCacheAbandoned = NO;
    _stateDirty = YES;
    if (!_claudeStatuslineLogged) { GBLog("claude: using statusline cache"); _claudeStatuslineLogged = YES; }
}

- (void)rememberClaudeFetchError:(NSDictionary *)fetch now:(double)now {
    [self rememberFetchError:fetch now:now token:&_claudeAccessToken expiresAt:&_claudeAccessTokenExpiresAt
                   nextFetch:&_claudeNextFetch status:&_claudeAccountStatus rateLimitStreak:&_claudeRateLimitStreak
                      client:@"Claude Code"];
}

static NSString *ISOStringFromEpoch(double epoch) {
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [iso stringFromDate:[NSDate dateWithTimeIntervalSince1970:epoch]];
}

// One account's fetch-if-due step: the throttle, the token, the request, and what to
// remember about the outcome. Shared by Claude and Cursor.
- (void)refreshAccountNamed:(const char *)label
                        use:(BOOL)use allow:(BOOL)allow now:(double)now
                  usageJSON:(NSDictionary *__strong *)usageJSON
              lastSuccessAt:(double *)lastSuccessAt nextFetch:(double *)nextFetch
              accountStatus:(NSString *__strong *)accountStatus
             fetchedThisRun:(BOOL *)fetchedThisRun cacheAbandoned:(BOOL *)cacheAbandoned
                 skipReason:(NSString *__strong *)skipReason
            rateLimitStreak:(NSUInteger *)rateLimitStreak
                      token:(NSString *(^)(void))tokenForNow
                    fetcher:(NSDictionary *(^)(NSString *))fetcher
                    onError:(void (^)(NSDictionary *))onError {
    if (ShouldFetchClaudeAccount(use, allow, *usageJSON != nil, (*accountStatus).length > 0, now, *nextFetch)) {
        *skipReason = nil;
        NSString *token = tokenForNow();
        // No token, no request: leave the schedule to the credential reader's own backoff
        // instead of spending the 15-minute slot on nothing.
        if (token) *nextFetch = now + kAccountPollInterval;   // the endpoints rate-limit readily
        NSDictionary *fetch = token ? fetcher(token) : nil;
        if ([fetch[@"_glancebarFetchError"] boolValue]) {
            onError(fetch);
            GBLog("%{public}s fetch: failed http=%ld rateLimited=%d", label,
                  (long)[fetch[@"statusCode"] integerValue], [fetch[@"rateLimited"] boolValue]);
        } else if (fetch && !fetch[@"error"]) {
            *usageJSON = fetch;
            *accountStatus = nil;
            *lastSuccessAt = now;
            *rateLimitStreak = 0;
            *fetchedThisRun = YES;
            *cacheAbandoned = NO;
            _stateDirty = _stateMustPersist = YES;
            [self savePersistentStateForcingWrite:YES];
            GBLog("%{public}s fetch: ok", label);
        } else if (token.length) {
            *accountStatus = @"Usage API unavailable";
            GBLog("%{public}s fetch: unusable response", label);
        }
    } else {
        NSString *skip = !allow ? @"hidden" : @"throttled";
        if (![skip isEqualToString:*skipReason]) {
            GBLog("%{public}s fetch: skipped (%{public}@)", label, skip);
            *skipReason = skip;
        }
    }
}

typedef NSArray<NSDictionary *> *(*GBWindowsFn)(NSDictionary *, double);
typedef NSDictionary *(*GBPickFn)(NSDictionary *, double);
typedef NSString *(*GBReasonFn)(NSDictionary *, NSString *, double);
typedef struct {
    GBWindowsFn liveWindows, staleWindows;
    GBPickFn pickLive, pickStale;
    GBReasonFn reason;
} GBAccountFunctions;

// The gauge, windows, staleness and status strings for one account response. Shared by
// Claude and Cursor; the provider supplies its pure functions and its wording.
- (void)applyAccountResponse:(NSDictionary *)usage to:(AIUsage *)u functions:(GBAccountFunctions)fns
               lastSuccessAt:(double)lastSuccessAt accountStatus:(NSString *)accountStatus
              fetchedThisRun:(BOOL)fetchedThisRun allowFetch:(BOOL)allowFetch
                  windowNoun:(NSString *)noun accountName:(NSString *)accountName
                  sourceLive:(NSString *)sourceLive sourceCached:(NSString *)sourceCached
              middleFallback:(NSString *)middleFallback
           unavailableReason:(NSString *)unavailable pausedReason:(NSString *)paused {
    double now = NSDate.date.timeIntervalSince1970;
    u.limitWindows = fns.liveWindows(usage, now);
    NSDictionary *pick = fns.pickLive(usage, now);
    BOOL usingStaleWindows = NO;
    if (!pick) {
        NSArray *staleWindows = fns.staleWindows(usage, now);
        pick = fns.pickStale(usage, now);
        if (pick) {
            u.limitWindows = staleWindows;
            usingStaleWindows = YES;
        }
    }
    NSString *fetchedAtISO = lastSuccessAt > 0 ? ISOStringFromEpoch(lastSuccessAt) : nil;
    if (pick) {
        u.limitStatusAvailable = YES;
        u.remainingFraction = [pick[@"remainingFraction"] doubleValue];
        u.limitUpdatedAt = lastSuccessAt > 0 ? [NSDate dateWithTimeIntervalSince1970:lastSuccessAt] : nil;
        NSNumber *resets = pick[@"resetsAt"];
        if (resets) {
            u.resetAt = [NSDate dateWithTimeIntervalSince1970:resets.doubleValue];
            u.resetText = ResetTextFromDate(u.resetAt);
        }
        BOOL fresh = [pick[@"fresh"] boolValue];
        if (fresh) {
            // A window nobody has used yet has no reset to count down to; its clock
            // starts on the first request. Say that instead of inventing a time.
            u.resetText = @"Not started";
            u.resetAt = nil;
        }
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        [parts addObject:noun.length ? [NSString stringWithFormat:@"%@ %@", pick[@"window"], noun] : pick[@"window"]];
        if (fresh) [parts addObject:@"nothing used yet"];
        [parts addObject:accountName];
        NSString *window = [parts componentsJoinedByString:@" · "];
        BOOL diskRestoredOnly = !fetchedThisRun && usage != nil;
        if (usingStaleWindows || diskRestoredOnly || accountStatus.length) u.limitStale = YES;
        NSString *asOf = AsOfTextFromEpoch(lastSuccessAt);
        if (accountStatus.length) {
            u.statusReason = asOf
                ? [NSString stringWithFormat:@"Cached limit · %@ · %@ · %@", accountStatus, window, asOf]
                : [NSString stringWithFormat:@"Cached limit · %@ · %@", accountStatus, window];
            u.statusSource = sourceCached;
        } else if (usingStaleWindows) {
            u.statusReason = fns.reason(usage, fetchedAtISO, now) ?: window;
            u.statusSource = sourceCached;
        } else if (diskRestoredOnly) {
            u.statusReason = asOf
                ? [NSString stringWithFormat:@"Cached limit · %@ · %@", window, asOf]
                : [@"Cached limit · " stringByAppendingString:window];
            u.statusSource = sourceCached;
        } else {
            u.statusReason = window;
            u.statusSource = sourceLive;
        }
    } else {
        NSString *fallback = fns.reason(usage, fetchedAtISO, now)
            ?: (usage ? @"Account response has no current limit window"
                : allowFetch ? unavailable : paused);
        u.statusReason = accountStatus ?: (middleFallback ?: fallback);
        if (allowFetch) u.limitRefreshError = accountStatus ?: fallback;
    }
    if (u.limitStatusAvailable && !u.limitUpdatedAt && lastSuccessAt > 0)
        u.limitUpdatedAt = [NSDate dateWithTimeIntervalSince1970:lastSuccessAt];
    if (accountStatus.length) u.limitRefreshError = accountStatus;
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
            u.source = @"~/.claude transcripts";
            // Activity comes from the same index. Claude Code stopped writing its stats
            // cache in June 2026, so the cache-derived figures above are months stale.
            u.models = _claudeModels ?: @[];
            u.topModel = u.models.count ? u.models.firstObject[@"name"] : nil;
            u.todaySessions = _claudeSessionsToday;
            u.weekSessions = _claudeSessionsWeek;
            u.todayMessages = _claudeMessagesToday;
            u.todayToolCalls = _claudeToolsToday;
            if (_claudeLastActivity) u.lastActivity = _claudeLastActivity;
        }
    } else {
        [self purgeClaudeTranscriptIndex];
        if (u.statusText.length)
            u.statusText = [u.statusText stringByAppendingString:@" · transcript totals off"];
    }

    if (self.useClaudeAccount) {
        double now = NSDate.date.timeIntervalSince1970;
        [self adoptClaudeStatuslineCacheAt:now];
        [self refreshAccountNamed:"claude" use:self.useClaudeAccount allow:self.allowClaudeAccountFetch now:now
                        usageJSON:&_claudeUsageJSON lastSuccessAt:&_claudeLastSuccessAt nextFetch:&_claudeNextFetch
                    accountStatus:&_claudeAccountStatus fetchedThisRun:&_claudeFetchedThisRun
                   cacheAbandoned:&_claudeUsageCacheAbandoned skipReason:&_claudeFetchSkipReason
                  rateLimitStreak:&_claudeRateLimitStreak
                            token:^NSString *{ return [self claudeAccessTokenForNow:now]; }
                          fetcher:^NSDictionary *(NSString *token){ return self.claudeUsageFetcher(token); }
                          onError:^(NSDictionary *fetch){ [self rememberClaudeFetchError:fetch now:now]; }];
        NSDictionary *extraStatus = ClaudeExtraUsageStatus(_claudeUsageJSON);
        if (extraStatus[@"description"]) u.extraUsage = extraStatus[@"description"];
        GBAccountFunctions fns = { ClaudeLimitWindows, ClaudeStaleLimitWindows,
                                   PickClaudeLimitWindow, PickClaudeStaleLimitWindow, ClaudeLimitStatusReason };
        [self applyAccountResponse:_claudeUsageJSON to:u functions:fns
                     lastSuccessAt:_claudeLastSuccessAt accountStatus:_claudeAccountStatus
                    fetchedThisRun:_claudeFetchedThisRun allowFetch:self.allowClaudeAccountFetch
                        windowNoun:@"window" accountName:@"your Claude account"
                        sourceLive:@"Anthropic usage API (opt-in)"
                      sourceCached:@"Cached Anthropic usage API response (opt-in)"
                    middleFallback:extraStatus[@"statusReason"]
                 unavailableReason:@"Claude account status unavailable"
                      pausedReason:@"Claude account refresh paused until visible"];
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
            u.limitUpdatedAt = [NSDate dateWithTimeIntervalSince1970:_claudeLastSuccessAt];   // overage path
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

// Withdrawn consent: the transcript index (message-ID hashes, per-day totals) must leave
// the disk NOW — the toggle calls this directly, because no read() runs while every AI
// surface is hidden and "on the next pass" may mean never.
- (void)purgeClaudeTranscriptIndex {
    BOOL hadIndex = _claudeFiles.count || _claudeDays.count;
    [_claudeFiles removeAllObjects];
    [_claudeDays removeAllObjects];
    _claudeInventory = nil;
    _claudeInventoryValidUntil = 0;
    _claudeTotalBytes = _claudeDoneBytes = 0;
    _claudeTotalsIncomplete = _claudeBlocked = NO;
    _claudeModels = @[];
    _claudeSessionsToday = _claudeSessionsWeek = _claudeMessagesToday = _claudeToolsToday = 0;
    _claudeLastActivity = nil;
    if (hadIndex) {
        _stateDirty = _stateMustPersist = YES;
        [self savePersistentStateForcingWrite:YES];
    }
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
    double cachedExp = JWTExpiryEpoch(_cursorAccessToken);
    if (_cursorAccessToken.length && !(cachedExp > 0 && cachedExp <= now)) return _cursorAccessToken;
    _cursorAccessToken = nil;
    if (now < _cursorStateNextTry) {
        if (!_cursorAccountStatus.length) _cursorAccountStatus = @"Cursor session unavailable; retrying later";
        return nil;
    }
    double readStart = CFAbsoluteTimeGetCurrent();
    NSString *token = self.cursorTokenReader(_homeDirectory);
    double readMs = (CFAbsoluteTimeGetCurrent() - readStart) * 1000.0;
    if (!token.length) {
        _cursorAccessToken = nil;
        _cursorStateNextTry = now + 3600;   // missing session: don't hammer sqlite every tick
        _cursorAccountStatus = @"Cursor session unavailable; retrying later";
        GBLog("cursor state read: missing (%.0f ms)", readMs);
        return nil;
    }
    double exp = JWTExpiryEpoch(token);
    if (exp > 0 && exp <= now) {
        // Every session we can see has expired: no request would succeed, so say how to fix
        // it and look again soon — signing in to either client takes effect within minutes.
        _cursorStateNextTry = now + 300;
        _cursorAccountStatus = AccountFetchFailureStatus(401, nil, @"Cursor");
        GBLog("cursor state read: expired (%.0f ms)", readMs);
        return nil;
    }
    _cursorAccessToken = token;
    _cursorStateNextTry = 0;
    GBLog("cursor state read: ok (%.0f ms)", readMs);
    return _cursorAccessToken;
}

- (void)rememberCursorFetchError:(NSDictionary *)fetch now:(double)now {
    if (ShouldDropCachedTokenForStatus([fetch[@"statusCode"] integerValue]))
        self.cursorRejectedToken = _cursorAccessToken;
    [self rememberFetchError:fetch now:now token:&_cursorAccessToken expiresAt:NULL
                   nextFetch:&_cursorNextFetch status:&_cursorAccountStatus rateLimitStreak:&_cursorRateLimitStreak
                      client:@"Cursor"];
}

- (AIUsage *)cursorUsage {
    AIUsage *u = [AIUsage new];
    u.name = @"Cursor";
    u.source = @"Cursor session (app or CLI) + api2.cursor.sh";
    u.remainingFraction = -1;
    u.resetText = @"Not exposed locally";
    u.statusReason = @"Cursor account access is off";
    u.models = @[];
    u.available = NO;

    if (self.useCursorAccount) {
        double now = NSDate.date.timeIntervalSince1970;
        [self refreshAccountNamed:"cursor" use:self.useCursorAccount allow:self.allowCursorAccountFetch now:now
                        usageJSON:&_cursorUsageJSON lastSuccessAt:&_cursorLastSuccessAt nextFetch:&_cursorNextFetch
                    accountStatus:&_cursorAccountStatus fetchedThisRun:&_cursorFetchedThisRun
                   cacheAbandoned:&_cursorUsageCacheAbandoned skipReason:&_cursorFetchSkipReason
                  rateLimitStreak:&_cursorRateLimitStreak
                            token:^NSString *{ return [self cursorAccessTokenForNow:now]; }
                          fetcher:^NSDictionary *(NSString *token){ return self.cursorUsageFetcher(token); }
                          onError:^(NSDictionary *fetch){ [self rememberCursorFetchError:fetch now:now]; }];
        GBAccountFunctions fns = { CursorLimitWindows, CursorStaleLimitWindows,
                                   PickCursorLimitWindow, PickCursorStaleLimitWindow, CursorLimitStatusReason };
        [self applyAccountResponse:_cursorUsageJSON to:u functions:fns
                     lastSuccessAt:_cursorLastSuccessAt accountStatus:_cursorAccountStatus
                    fetchedThisRun:_cursorFetchedThisRun allowFetch:self.allowCursorAccountFetch
                        windowNoun:nil accountName:@"your Cursor account"
                        sourceLive:@"Cursor usage API (opt-in)"
                      sourceCached:@"Cached Cursor usage API response (opt-in)"
                    middleFallback:nil
                 unavailableReason:@"Cursor account status unavailable"
                      pausedReason:@"Cursor account refresh paused until visible"];
        if (u.limitStatusAvailable) {
            u.available = YES;
            u.statusText = @"Limit status from Cursor account";
        }
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
    if (!path) { _sessionsToday = _sessionsWeek = 0; _models = @[]; _lastActivity = nil; return; }
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
    NSString *weekSQL = [NSString stringWithFormat:@"select count(*) from threads where updated_at >= %lld;",
                         (long long)weekStart.timeIntervalSince1970];
    _sessionsWeek = [[[RunSQLite(path, weekSQL) stringByTrimmingCharactersInSet:
                       NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@"\n"].firstObject longLongValue];
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
    u.weekSessions = _sessionsWeek;
    u.lastActivity = _lastActivity;
    if (u.models.count) u.topModel = u.models.firstObject[@"name"];

    // Read drift from the newest snapshot as it arrived, not from the merged view.
    NSString *drift = CodexSchemaDriftReason(_limitsNewest);
    u.limitWindows = CodexBucketWindows(_buckets, now);
    NSDictionary *planBuckets = _buckets[@"codex"] ? @{@"codex": _buckets[@"codex"]} : @{};
    NSDictionary *pick = PickCodexBucketWindow(planBuckets, now);
    u.billingNote = CodexBillingNote(_buckets, now);
    NSMutableSet *bucketsShown = [NSMutableSet set];
    for (NSDictionary *w in u.limitWindows) if (w[@"bucket"]) [bucketsShown addObject:w[@"bucket"]];
    if (pick) {
        u.limitStatusAvailable = YES;
        u.remainingFraction = [pick[@"remainingFraction"] doubleValue];
        NSNumber *resets = pick[@"resetsAt"];
        if (resets) {
            u.resetAt = [NSDate dateWithTimeIntervalSince1970:resets.doubleValue];
            u.resetText = ResetTextFromDate(u.resetAt);
        }
        NSString *plan = [pick[@"plan"] isKindOfClass:NSString.class] ? pick[@"plan"] : nil;
        // Name the bucket only when more than one is on show; with a single bucket the
        // window name says it all, as it always did.
        NSString *window = bucketsShown.count > 1
            ? [NSString stringWithFormat:@"%@ window · %@ bucket", pick[@"window"], pick[@"bucketLabel"]]
            : [NSString stringWithFormat:@"%@ window", pick[@"window"]];
        u.statusReason = plan.length ? [NSString stringWithFormat:@"%@ · %@ plan", window, plan] : window;
        if (u.billingNote.length) u.statusReason = [u.statusReason stringByAppendingFormat:@" · %@", u.billingNote];
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
    else u.statusReason = drift ?: CodexBucketsStatusReason(planBuckets, now);

    // Context, never the gauge: a zero credit balance is normal while the plan window
    // still has room. See CodexCreditsStatus. Credits are account-level; read them from
    // whichever bucket reported them last.
    NSDictionary *credits = CodexCreditsStatus(CodexNewestBucketLimits(_buckets));
    for (NSString *bucketID in _buckets) {
        if (credits) break;
        NSDictionary *entry = _buckets[bucketID];
        credits = CodexCreditsStatus([entry[@"limits"] isKindOfClass:NSDictionary.class] ? entry[@"limits"] : nil);
    }
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
    for (NSString *bucketID in [_buckets.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *entry = _buckets[bucketID];
        NSDictionary *limits = [entry[@"limits"] isKindOfClass:NSDictionary.class] ? entry[@"limits"] : nil;
        for (NSString *key in @[@"primary", @"secondary"]) {
            NSDictionary *w = [limits[key] isKindOfClass:NSDictionary.class] ? limits[key] : nil;
            if (![w[@"used_percent"] isKindOfClass:NSNumber.class]) continue;
            anyUsable = YES;
            double resets = [w[@"resets_at"] isKindOfClass:NSNumber.class] ? [w[@"resets_at"] doubleValue] : 0;
            BOOL expired = resets > 0 && resets <= now;
            if (!expired) anyCurrent = YES;
            long mins = [w[@"window_minutes"] isKindOfClass:NSNumber.class] ? [w[@"window_minutes"] longValue] : 0;
            [parts addObject:[NSString stringWithFormat:@"%@ %@ %.0f%% used · reset %@%@", bucketID,
                mins == 10080 ? @"weekly" : mins == 300 ? @"5h" : @"window",
                [w[@"used_percent"] doubleValue], FmtEpochDayClock(resets), expired ? @" (expired)" : @""]];
        }
    }
    NSString *newestBucket = CodexNewestBucketID(_buckets);
    if (newestBucket.length) [parts addObject:[@"newest bucket " stringByAppendingString:newestBucket]];
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
    [self adoptNewerAccountCachesFromDisk];
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
    else [self flushPersistentState];
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
// SF Symbol battery.100 / .75 / .50 / .25 / .0. The bolt variant exists only for
// battery.100 (battery.75.bolt and the rest are not in the system set); fall back
// to the plain level rather than hand AppKit a nil image.
static NSString *BatterySymbolName(int percent, BOOL plugged) {
    int bucket = 0;
    if (percent >= 88) bucket = 100;
    else if (percent >= 63) bucket = 75;
    else if (percent >= 38) bucket = 50;
    else if (percent >= 13) bucket = 25;
    if (plugged) {
        NSString *bolt = [NSString stringWithFormat:@"battery.%d.bolt", bucket];
        if ([NSImage imageWithSystemSymbolName:bolt accessibilityDescription:nil]) return bolt;
    }
    return [NSString stringWithFormat:@"battery.%d", bucket];
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

static NSColor *AIQuotaColor(double fraction) {
    if (fraction <= 0.15) return NSColor.systemRedColor;
    if (fraction <= 0.35) return NSColor.systemOrangeColor;
    if (fraction <= 0.60) return [NSColor.systemYellowColor colorWithAlphaComponent:0.9];
    return NSColor.systemGreenColor;
}

// Overlay distinct endpoints; use fixed lanes only when they are nearly equal.
static BOOL ClaudeQuotasClose(double fable, double opus) {
    return fable >= 0 && opus >= 0 && fabs(fable-opus) <= 0.030000001;
}
static NSColor *ClaudeQuotaColor(double fraction) {
    return fraction > 0.35 ? NSColor.systemGreenColor : AIQuotaColor(fraction);
}
@interface ClaudeGauge : NSView
@property (nonatomic) double fable, opus; // negative = not reported
@end
@implementation ClaudeGauge
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _fable = _opus = -1;
        [self setAccessibilityElement:YES];
        self.accessibilityRole = NSAccessibilityImageRole;
        self.accessibilityLabel = @"Claude quota remaining: Fable and Opus";
        self.accessibilityIdentifier = @"popover.claude.meter";
    }
    return self;
}
- (void)refreshValues {
    NSString *f = _fable < 0 ? @"not reported" : [NSString stringWithFormat:@"%.0f%%", _fable*100];
    NSString *o = _opus < 0 ? @"not reported" : [NSString stringWithFormat:@"%.0f%%", _opus*100];
    self.accessibilityValue = _fable < 0 ? [o stringByAppendingString:@" remaining"]   // single weekly figure
        : [NSString stringWithFormat:@"Fable %@, Opus %@ remaining", f, o];
    self.needsDisplay = YES;
}
- (void)setFable:(double)value { _fable = value < 0 ? -1 : MIN(1, MAX(0, value)); [self refreshValues]; }
- (void)setOpus:(double)value { _opus = value < 0 ? -1 : MIN(1, MAX(0, value)); [self refreshValues]; }
- (void)drawRect:(NSRect)dirty {
    NSRect r = self.bounds;
    BOOL lanes = ClaudeQuotasClose(_fable, _opus);
    CGFloat laneHeight = MAX(0, (r.size.height-1)/2);
    NSBezierPath *wholeTrack = [NSBezierPath bezierPathWithRoundedRect:r xRadius:r.size.height/2 yRadius:r.size.height/2];
    if (!lanes) { [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [wholeTrack fill]; }
    for (int i=0; i<2; i++) {
        // Draw longer first in overlay mode, but keep Fable above in lane mode.
        BOOL fable = lanes ? i == 0 : (i == 0 ? _fable > _opus : _fable <= _opus);
        double value = fable ? _fable : _opus;
        NSRect lane = lanes ? NSMakeRect(r.origin.x, r.origin.y + (fable ? laneHeight+1 : 0), r.size.width, laneHeight) : r;
        CGFloat radius = lane.size.height/2;
        NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:lane xRadius:radius yRadius:radius];
        if (lanes) { [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [track fill]; }
        if (value <= 0) continue;
        [NSGraphicsContext saveGraphicsState]; [track addClip];
        NSRect fill = lane; fill.size.width *= value;
        NSColor *color = ClaudeQuotaColor(value);
        // Overlay: the longer fill is drawn first. When both fills would share one colour
        // the longer one is a lighter tint, so the solid part reads "both models have this
        // much" and the tinted extension "only the larger one does" — a one-pixel divider
        // was not legible.
        if (!lanes && i == 0 && _fable > 0 && _opus > 0 && [color isEqual:ClaudeQuotaColor(MIN(_fable, _opus))])
            color = [color colorWithAlphaComponent:0.4];
        [color setFill]; NSRectFill(fill);
        [NSGraphicsContext restoreGraphicsState];
    }
}
@end

// The whole instrument row is the control. hitTest returns self so the labels
// do not eat the click that opens Details.
@interface ClickRow : NSView
@property (nonatomic, weak) id target;
@property (nonatomic) SEL action;
@end
@implementation ClickRow
- (NSView *)hitTest:(NSPoint)point {
    return NSPointInRect(point, self.bounds) ? self : nil;
}
- (void)mouseDown:(NSEvent *)event { (void)event; }
- (void)sendAction {
    if (!self.target || !self.action) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [self.target performSelector:self.action withObject:self];
#pragma clang diagnostic pop
}
- (void)mouseUp:(NSEvent *)event {
    if (!NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds)) return;
    [self sendAction];
}
- (BOOL)accessibilityPerformPress {
    [self sendAction];
    return YES;
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
// A pill whose own fill carries its on/off state. A push button's bezelColor draws only
// while its window is key, and the popover belongs to a background app that never
// activates — so a tinted bezel never appeared there, and Keep Awake looked dead.
@interface PillButton : NSButton
@property (nonatomic, strong) NSColor *onColor;
@end
@implementation PillButton
- (void)drawRect:(NSRect)dirtyRect {
    BOOL on = self.state == NSControlStateValueOn;
    CGFloat alpha = self.isHighlighted ? 0.16 : 0.08;
    [(on ? self.onColor : [NSColor.labelColor colorWithAlphaComponent:alpha]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
    if (on && self.isHighlighted) {
        [[NSColor.blackColor colorWithAlphaComponent:0.12] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
    }
    [super drawRect:dirtyRect];
}
@end

// Left click cycles outputs. Right click (and Option-click, handled in the action)
// opens the full device menu.
@interface OutputCycleButton : NSButton
@end
@implementation OutputCycleButton
- (void)rightMouseDown:(NSEvent *)event {
    (void)event;
    if (self.target && self.action) [self sendAction:self.action to:self.target];
}
@end

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
        old.font = new.font;
        old.textColor = new.textColor;
        // textColor paints the whole string. Put the attributed value back last so the
        // system row keeps its per-word colours across an in-place refresh.
        if (![old.attributedStringValue isEqualToAttributedString:new.attributedStringValue])
            old.attributedStringValue = new.attributedStringValue;
        else if (![old.stringValue isEqualToString:new.stringValue]) old.stringValue = new.stringValue;
        old.alignment = new.alignment;
        old.lineBreakMode = new.lineBreakMode;
        old.maximumNumberOfLines = new.maximumNumberOfLines;
        if (old.selectable != new.selectable) old.selectable = new.selectable;
    } else if ([existing isKindOfClass:NSButton.class]) {
        NSButton *old = (NSButton *)existing, *new = (NSButton *)fresh;
        old.title = new.title;
        // A pill's icon carries its state (play ↔ pause, cup vs tortoise); without these
        // an in-place refresh kept the old glyph and colour behind a new label.
        if (new.attributedTitle.length && ![old.attributedTitle isEqual:new.attributedTitle])
            old.attributedTitle = new.attributedTitle;
        old.image = new.image;
        old.imagePosition = new.imagePosition;
        old.target = new.target;
        old.action = new.action;
        old.enabled = new.enabled;
        old.state = new.state;
        old.contentTintColor = new.contentTintColor;
        if ([old isKindOfClass:PillButton.class] && [new isKindOfClass:PillButton.class])
            ((PillButton *)old).onColor = ((PillButton *)new).onColor;
        old.needsDisplay = YES;
    } else if ([existing isKindOfClass:NSImageView.class]) {
        NSImageView *old = (NSImageView *)existing, *new = (NSImageView *)fresh;
        old.image = new.image;
        old.contentTintColor = new.contentTintColor;
    } else if ([existing isKindOfClass:ClaudeGauge.class]) {
        ClaudeGauge *old = (ClaudeGauge *)existing, *new = (ClaudeGauge *)fresh;
        old.fable = new.fable; old.opus = new.opus;
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

// Two glyphs drawn side by side as one image, centred vertically (Keep Awake + Low Power).
static NSImage *GlyphPair(NSImage *a, NSImage *b) {
    if (!a || !b) return a ?: b;
    CGFloat gap = 3, h = MAX(a.size.height, b.size.height);
    NSImage *out = [[NSImage alloc] initWithSize:NSMakeSize(a.size.width + gap + b.size.width, h)];
    [out lockFocus];
    [a drawInRect:NSMakeRect(0, (h - a.size.height) / 2, a.size.width, a.size.height)];
    [b drawInRect:NSMakeRect(a.size.width + gap, (h - b.size.height) / 2, b.size.width, b.size.height)];
    [out unlockFocus];
    out.template = NO;
    return out;
}
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

    // Keep the hard-drive silhouette, but put usage on a rectangular front face:
    // equal changes in capacity now move a straight edge by equal distances.
    NSBezierPath *top = [NSBezierPath bezierPath];
    [top moveToPoint:NSMakePoint(1, 7.5)];
    [top lineToPoint:NSMakePoint(3, 11.8)];
    [top curveToPoint:NSMakePoint(4.2, 12.8) controlPoint1:NSMakePoint(3.2, 12.5) controlPoint2:NSMakePoint(3.5, 12.8)];
    [top lineToPoint:NSMakePoint(12.8, 12.8)];
    [top curveToPoint:NSMakePoint(14, 11.8) controlPoint1:NSMakePoint(13.5, 12.8) controlPoint2:NSMakePoint(13.8, 12.5)];
    [top lineToPoint:NSMakePoint(16, 7.5)];
    [top closePath];
    [[fg colorWithAlphaComponent:0.12] setFill]; [top fill];
    [fg setStroke]; top.lineWidth = 1.1; [top stroke];

    NSBezierPath *front = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1, 1.5, 15, 6.3)
                                                                  xRadius:1.1 yRadius:1.1];
    [fg setStroke]; front.lineWidth = 1.1; [front stroke];
    NSRect meter = NSMakeRect(2.6, 3.1, 11.8, 3.1);
    [[fg colorWithAlphaComponent:0.12] setFill]; NSRectFill(meter);
    [(fill ?: fg) setFill];
    meter.size.width *= fraction;
    if (fraction > 0) NSRectFill(meter);
    // The indicator belongs on the lid so it cannot obscure the usage meter.
    [fg setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(11.4, 9.4, 1.2, 1.2)] fill];

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
        // The space separates text from its icon; a text-only segment (compact battery
        // percentage) gets none, or it sits 3.5pt off-centre inside its own host.
        NSString *drawText = text.length ? (sym ? [@" " stringByAppendingString:text] : text) : @"";
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
// One instrument row. Lead, gauge, value and datum share these x positions so
// storage, battery and every AI provider line up. kDatumX + kDatumW == kW - kPad.
// Density is signal per area, not a small panel: space freed from words goes to
// legible instruments (30pt rows, 8pt gauges, 15pt values), not to shrinking.
static const CGFloat kRowH = 30, kSoundH = 40;
static const CGFloat kLeadW = 52;                              // "Cursor" at 13pt, or a 22pt symbol
static const CGFloat kLeadSymbol = 22;
static const CGFloat kGaugeX = 74, kGaugeW = 78, kGaugeH = 8;  // kPad + kLeadW + 6
static const CGFloat kValueX = 156, kValueW = 48;              // "100%" at 15pt
static const CGFloat kDatumX = 212, kDatumW = 92;              // "220 GB free"
static const CGFloat kValueH = 19, kDatumH = 16, kDatumFont = 12.5;
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
- (void)schedulePowerRefresh;
- (dispatch_queue_t)pmsetWorkQueue;
- (void)refreshAIUsageAsync;
- (void)refreshLidAwakeAsync;
- (void)refreshLidAwakeForced:(BOOL)force;
- (void)updateBar;
- (void)refreshVisibleSurfaces;
- (NSDictionary *)focusSnapshotForWindow:(NSWindow *)window rootView:(NSView *)root;
- (void)restoreFocus:(NSDictionary *)snapshot
             inView:(NSView *)root window:(NSWindow *)window;
- (void)audioDevicesChanged;
- (void)audioDefaultChanged;
@end

// CoreAudio property reads. Output streams are the output scope of kAudioDevicePropertyStreams;
// a stream direction of 0 is output (AudioHardwareBase.h). Default output is
// kAudioHardwarePropertyDefaultOutputDevice; alert sounds follow
// kAudioHardwarePropertyDefaultSystemOutputDevice. Listeners are AudioObjectAddPropertyListener
// on kAudioObjectSystemObject — no polling.
// https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertydefaultoutputdevice
static AudioObjectPropertyAddress AudioAddr(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){ selector, scope, kAudioObjectPropertyElementMain };
}
static NSString *AudioString(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress addr = AudioAddr(selector, kAudioObjectPropertyScopeGlobal);
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(object, &addr, 0, NULL, &size, &value) != noErr || !value) return nil;
    return (__bridge_transfer NSString *)value;
}
static GlanceAudioTransport GlanceTransport(UInt32 transport) {
    switch (transport) {
    case kAudioDeviceTransportTypeBuiltIn: return GlanceAudioTransportBuiltIn;
    case kAudioDeviceTransportTypeBluetooth:
    case kAudioDeviceTransportTypeBluetoothLE: return GlanceAudioTransportBluetooth;
    case kAudioDeviceTransportTypeUSB: return GlanceAudioTransportUSB;
    case kAudioDeviceTransportTypeHDMI:
    case kAudioDeviceTransportTypeDisplayPort: return GlanceAudioTransportDisplay;
    case kAudioDeviceTransportTypeAggregate: return GlanceAudioTransportAggregate;
    case kAudioDeviceTransportTypeVirtual: return GlanceAudioTransportVirtual;
    default: return GlanceAudioTransportOther;
    }
}
static NSString *AudioDataSourceName(AudioObjectID device) {
    AudioObjectPropertyAddress addr = AudioAddr(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput);
    UInt32 source = 0, size = sizeof(source);
    if (AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, &source) != noErr) return @"";
    CFStringRef name = NULL;
    AudioValueTranslation translation = { &source, sizeof(source), &name, sizeof(name) };
    size = sizeof(translation);
    addr.mSelector = kAudioDevicePropertyDataSourceNameForIDCFString;
    if (AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, &translation) != noErr || !name) return @"";
    return (__bridge_transfer NSString *)name;
}
static int OutputChannelCount(AudioObjectID device) {
    AudioObjectPropertyAddress addr = AudioAddr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &addr, 0, NULL, &size) != noErr || size < sizeof(AudioObjectID))
        return 0;
    UInt32 count = size / sizeof(AudioObjectID);
    AudioObjectID *streams = calloc(count, sizeof(AudioObjectID));
    if (!streams) return 0;
    int channels = 0;
    if (AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, streams) == noErr) {
        for (UInt32 i = 0; i < count; i++) {
            AudioStreamBasicDescription format = {0};
            AudioObjectPropertyAddress formatAddr = AudioAddr(kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal);
            UInt32 formatSize = sizeof(format);
            if (AudioObjectGetPropertyData(streams[i], &formatAddr, 0, NULL, &formatSize, &format) == noErr &&
                format.mChannelsPerFrame > 0)
                channels += (int)format.mChannelsPerFrame;
            else
                channels += 1;
        }
    }
    free(streams);
    return channels;
}
static NSArray<NSDictionary *> *ReadAudioDevices(void) {
    AudioObjectPropertyAddress addr = AudioAddr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr || !size)
        return @[];
    UInt32 count = size / sizeof(AudioObjectID);
    AudioObjectID *devices = calloc(count, sizeof(AudioObjectID));
    if (!devices) return @[];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devices) != noErr) {
        free(devices);
        return @[];
    }
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithCapacity:count];
    for (UInt32 i = 0; i < count; i++) {
        AudioObjectPropertyAddress transportAddr = AudioAddr(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal);
        UInt32 transport = 0, transportSize = sizeof(transport);
        AudioObjectGetPropertyData(devices[i], &transportAddr, 0, NULL, &transportSize, &transport);
        NSString *uid = AudioString(devices[i], kAudioDevicePropertyDeviceUID);
        if (!uid.length) continue;
        NSString *name = AudioString(devices[i], kAudioObjectPropertyName) ?: @"Output";
        [rows addObject:@{
            @"uid": uid, @"name": name, @"transport": @(GlanceTransport(transport)),
            @"outputChannels": @(OutputChannelCount(devices[i])), @"deviceID": @(devices[i]),
            @"dataSource": AudioDataSourceName(devices[i]) ?: @""
        }];
    }
    free(devices);
    return rows;
}
static NSString *DefaultOutputUID(NSArray<NSDictionary *> *devices) {
    AudioObjectID device = kAudioObjectUnknown;
    AudioObjectPropertyAddress addr = AudioAddr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &device) != noErr || !device)
        return nil;
    for (NSDictionary *row in devices)
        if ([row[@"deviceID"] unsignedIntValue] == device) return row[@"uid"];
    return AudioString(device, kAudioDevicePropertyDeviceUID);
}
static void SetOutputDevice(AudioObjectID device) {
    if (!device) return;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress addr = AudioAddr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, size, &device);
    addr.mSelector = kAudioHardwarePropertyDefaultSystemOutputDevice;
    AudioObjectSetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, size, &device);
}
static BOOL SwitchToNewOutputs(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud registerDefaults:@{@"switchToNewOutputs": @YES}];
    return [ud boolForKey:@"switchToNewOutputs"];
}
static OSStatus AudioHardwareChanged(AudioObjectID object, UInt32 count,
                                    const AudioObjectPropertyAddress *addresses, void *client) {
    (void)object;
    BOOL devices = NO, output = NO;
    for (UInt32 i = 0; i < count; i++) {
        if (addresses[i].mSelector == kAudioHardwarePropertyDevices) devices = YES;
        if (addresses[i].mSelector == kAudioHardwarePropertyDefaultOutputDevice) output = YES;
    }
    Controller *controller = (__bridge Controller *)client;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (devices) [controller audioDevicesChanged];
        if (output) [controller audioDefaultChanged];
    });
    return noErr;
}

static NSString *AudioSymbolName(NSDictionary *device) {
    return AudioOutputSymbol((GlanceAudioTransport)[device[@"transport"] integerValue],
                             device[@"name"], device[@"dataSource"]);
}
static void PostSystemMediaKey(UInt32 keyCode) {
    void (^post)(BOOL) = ^(BOOL up) {
        NSEvent *event = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                             location:NSZeroPoint
                                        modifierFlags:up ? 0xb00 : 0xa00
                                            timestamp:0
                                         windowNumber:0
                                              context:nil
                                              subtype:8
                                                data1:((keyCode << 16) | ((up ? 0xBu : 0xAu) << 8))
                                                data2:-1];
        if (event.CGEvent) CGEventPost(kCGHIDEventTap, event.CGEvent);
    };
    post(NO);
    post(YES);
}
static BOOL ChromeIsRunning(void) {
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.google.Chrome"].count > 0;
}
static void RunAppleScript(NSString *source, void (^done)(NSString *output, NSString *errorText, int status)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
        task.arguments = @[@"-e", source ?: @""];
        NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
        task.standardOutput = out;
        task.standardError = err;
        if (![task launchAndReturnError:NULL]) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(@"", @"osascript failed to launch", 1); });
            return;
        }
        // osascript has no deadline. A hung Chrome, or a permission dialog nobody answers,
        // would block this queue forever; terminate at 10s and force-kill at 11s.
        GBWatchdog *watchdog = [[GBWatchdog alloc] initWithPid:task.processIdentifier seconds:10];
        NSString *output = [[NSString alloc] initWithData:[out.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @"";
        NSString *errorText = [[NSString alloc] initWithData:[err.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @"";
        [task waitUntilExit];
        [watchdog disarm];
        int status = task.terminationStatus;
        if (task.terminationReason != NSTaskTerminationReasonExit) {
            if (!errorText.length) errorText = @"osascript timed out";
            if (status == 0) status = 1;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(output, errorText, status); });
    });
}
// One round trip finds the music.youtube.com tab and runs the action there.
// status only reads. start is the one place shuffle is forced on, and only when
// Glancebar itself is starting playback. The JS stays inside one double-quoted
// AppleScript string, so it cannot contain a double quote; fields come back
// separated by ASCII 31 (YouTubeStatusSeparator) because titles contain '|'.
// Fields: tab, state, title, artist, playlist count, elapsed seconds, duration seconds.
static NSString *YouTubeControlScript(NSString *action) {
    if (![action isEqual:@"start"] && ![action isEqual:@"playpause"] &&
        ![action isEqual:@"next"] && ![action isEqual:@"previous"])
        action = @"status";
    NSString *js = [NSString stringWithFormat:
        @"(function(){var action='%@';"
        "function ws(c){return c===' '||c===String.fromCharCode(10)||c===String.fromCharCode(9)||c===String.fromCharCode(13);}"
        "function trim(s){s=s||'';while(s.length&&ws(s.charAt(0)))s=s.substring(1);while(s.length&&ws(s.charAt(s.length-1)))s=s.substring(0,s.length-1);return s;}"
        "function label(el){return ((el.getAttribute('aria-label')||'')+' '+(el.getAttribute('title')||'')).toLowerCase();}"
        "var bar=document.querySelector('ytmusic-player-bar');"
        "var video=document.querySelector('video');"
        "if(action==='playpause'){"
        "if(video){if(video.paused){var pr=video.play();if(pr&&pr.catch)pr.catch(function(){var fb=document.querySelector('#play-pause-button');if(fb)fb.click();});}else video.pause();}"
        "else{var pb=document.querySelector('#play-pause-button');if(pb)pb.click();}"
        "}else if(action==='next'){"
        "var nx=bar&&bar.querySelector('.next-button');if(nx)nx.click();"
        "}else if(action==='previous'){"
        "var pv=bar&&bar.querySelector('.previous-button');if(pv)pv.click();"
        "}else if(action==='start'){"
        "var buttons=document.querySelectorAll('button,[role=button],[role=switch]');"
        "var shuffle=null;"
        "for(var i=0;i<buttons.length;i++){var l=label(buttons[i]);if(l.indexOf('shuffle')!==-1){shuffle=buttons[i];break;}}"
        "if(shuffle){var sl=label(shuffle);var pressed=(shuffle.getAttribute('aria-pressed')||'').toLowerCase();var on=pressed==='true'||sl.indexOf('turn off shuffle')!==-1||sl.indexOf('shuffle on')!==-1||sl.indexOf('disable shuffle')!==-1;if(!on)shuffle.click();}"
        "if(video){if(video.paused){var sp=video.play();if(sp&&sp.catch)sp.catch(function(){var fb=document.querySelector('#play-pause-button');if(fb)fb.click();});}}"
        "else{var sb=document.querySelector('#play-pause-button');if(sb){var sbl=label(sb);if(sbl.indexOf('pause')===-1)sb.click();}}"
        "}"
        "var playing='unknown';"
        "if(video)playing=video.paused?'paused':'playing';"
        "var title='';var artist='';"
        "var session=navigator.mediaSession;var md=session&&session.metadata;"
        "if(md&&(md.title||md.artist)){title=md.title||'';artist=md.artist||'';}"
        "else if(bar){var te=bar.querySelector('.title');var be=bar.querySelector('.byline');title=te?(te.textContent||''):'';artist=be?(be.textContent||''):'';}"
        "var us=String.fromCharCode(31);"
        "function scrub(s){return trim(s).split(us).join('');}"
        "title=scrub(title);artist=scrub(artist);"
        "function isCount(t){var low=t.toLowerCase();var sp=low.indexOf(' song');if(sp<1)return false;for(var ci=0;ci<sp;ci++){var ch=low.charAt(ci);if(!((ch>='0'&&ch<='9')||ch===','))return false;}var rest=low.substring(sp);return rest===' song'||rest===' songs';}"
        "var countText='';"
        "var nodes=action==='start'?document.querySelectorAll('yt-formatted-string, span'):[];"
        "for(var j=0;j<nodes.length&&j<5000;j++){var ct=trim(nodes[j].textContent||'');if(isCount(ct)){countText=ct;break;}}"
        "function num(v){return (typeof v==='number'&&isFinite(v))?(''+v):'';}"
        "var elapsed=video?num(video.currentTime):'';"
        "var duration=video?num(video.duration):'';"
        "return 'yes'+us+playing+us+title+us+artist+us+countText+us+elapsed+us+duration;})()",
        action];
    return [NSString stringWithFormat:
        @"tell application \"Google Chrome\"\n"
        "set js to \"%@\"\n"
        "repeat with w in windows\n"
        "repeat with t in tabs of w\n"
        "if (URL of t) contains \"music.youtube.com\" then return execute javascript js in t\n"
        "end repeat\n"
        "end repeat\n"
        "return \"\"\n"
        "end tell", js];
}
static NSString *const kYouTubeJSNote = @"Enable Chrome ▸ View ▸ Developer ▸ Allow JavaScript from Apple Events to control playback";
static NSString *const kYouTubeAutomationNote = @"Allow Glancebar to control Chrome: System Settings ▸ Privacy & Security ▸ Automation";
static NSString *const kYouTubeChromeNote = @"Chrome unavailable — playing offline music";

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
    CFAbsoluteTime _volumeScanStarted;
    BOOL _powerRefreshPending;
    dispatch_queue_t _pmsetQueue;
    BOOL _pmsetInFlight;
    volatile BOOL _terminating;
    NSUInteger _volumeScanGen;
    CFAbsoluteTime _volumeAbandonedAt;
    NSString *_barCapacityKey;
    double _barCapacityCached, _barCapacityMeasuredAt;
    NSString *_aiSignature;
    NSString *_aiCatchUpStatus;
    BOOL _aiTotalsIncomplete;
    NSArray<NSDictionary *> *_hogs;
    NSArray<NSDictionary *> *_topCPU, *_topMem;
    NSMutableArray<NSNumber *> *_ampHistory;
    NSUInteger _sampleGen;
    CFAbsoluteTime _lastSampleTime;
    BOOL _showWatts, _showHealth, _hogsLoading, _hogsUnavailable;
    BOOL _barShowDisk, _barShowBattery, _barShowSystem;
    // Keep Awake IS the system SleepDisabled setting (no idle or lid-close sleep), read off-main.
    // One live state, so the bar's cup and the footer button can never disagree.
    BOOL _lidAwake, _lidAwakeReading;
    NSButton *_keepAwakeButton, *_lowPowerButton;   // footer toggles; rebuilt with the popover
    BOOL _aiGatesLogged, _lastShowAI, _lastUseAccount, _lastUseCursorAccount, _lastAllowTranscripts;
    BOOL _procStatsLoading, _procStatsUnavailable;
    CFAbsoluteTime _popoverClosedAt;   // guards the status-item click-to-dismiss race
    BarTierState _barTier;             // adaptive bar width; zero-init = full tier
    BOOL _barWasOnBar;                 // arms the eviction net only after a real sighting
    double _barCreatedAt;              // eviction grace for an item never sighted (crowded launch)
    BOOL _barSwapPending;              // a differently sized image was just installed…
    double _barFrameBeforeSwap;        // …and the host frame has not moved off this width yet
    double _lidAwakeLastRead;
    double _barChromeWidth;            // shell padding around the rendered image (16pt live)
    BOOL _barChromeKnown;
    NSDate *_lastMachineRefresh, *_lastAIRefresh;
    NSDate *_lastVolumeSuccess;
    NSScrollView *_popoverScroll;
    NSArray<NSDictionary *> *_audioDevices;    // last settled device set, including input-only
    NSArray<NSDictionary *> *_audioPrevious;   // comparison baseline for auto-switch
    NSString *_defaultOutputUID;
    NSUInteger _audioSettleGen;
    BOOL _musicProbesEnabled;          // app launch only; layout tests must not touch Chrome or audio
    BOOL _networkKnown, _networkOnline;
    nw_path_monitor_t _pathMonitor;
    BOOL _ytTabOpen, _playbackKnown, _playbackPlaying, _localMode, _localEmpty;
    BOOL _ytJSDenied, _ytStartPending, _ytStatusInFlight, _offlineTracksEntering;
    NSString *_localTitle, *_localArtist, *_ytTitle, *_ytArtist, *_musicNote;
    AVQueuePlayer *_localPlayer;
    NSArray<NSURL *> *_localURLs;
    NSArray<AVPlayerItem *> *_localObservedItems;
    NSInteger _localIndex;
    NSUInteger _musicGen;
    BOOL _remoteCommandsOn;
    NSTimer *_ytProbeTimer;
    CFAbsoluteTime _ytTabOpenedAt;
    NSArray<NSString *> *_offlineTracks;
    CFAbsoluteTime _offlineTracksAt;
    BOOL _offlineTracksReady;
    double _trackElapsed, _trackDuration;   // last probe; the tick interpolates from _trackSampledAt
    CFAbsoluteTime _trackSampledAt;
    NSTimer *_trackTick;
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
    // Keep Awake must not outlive the app when the sudoers rule can clear it without a
    // prompt. The plist read is cheap; its pmset fallback and the sudo each sit under the
    // 8s task watchdog. Stay synchronous — the process is quitting — but don't give them
    // the main thread for longer than the shared budget.
    _terminating = YES;
    dispatch_semaphore_t pmsetDone = dispatch_semaphore_create(0);
    // Not behind the pmset queue: an apply waiting on a password dialog would eat the budget.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSNumber *awake = SleepDisabledState();
        if (awake.boolValue && PmsetRuleInstalled()) RunPmsetViaSudo(@"disablesleep", NO);
        dispatch_semaphore_signal(pmsetDone);
    });
    if (dispatch_semaphore_wait(pmsetDone, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kQuitPmsetBudgetSec * NSEC_PER_SEC))))
        GBLog("terminate: Keep Awake cleanup timed out");
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
                           @"barShowSystem": @NO,
                           @"useClaudeAccount": @NO, @"useClaudeTranscripts": @NO,
                           @"useCursorAccount": @NO, @"switchToNewOutputs": @YES}];
    _bat = ReadBattery();
    _showWatts = [ud boolForKey:@"showWatts"];
    _showHealth = [ud boolForKey:@"showHealth"];
    _barShowDisk = [ud boolForKey:@"barShowDisk"];
    _barShowBattery = [ud boolForKey:@"barShowBattery"];
    _barShowSystem = [ud boolForKey:@"barShowSystem"];
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
    _barCreatedAt = CFAbsoluteTimeGetCurrent();
    // Diagnostic launch: exercise real shell placement and recovery from the glyph.
    const char *startCollapsed = getenv("GLANCEBAR_BAR_START_COLLAPSED");
    if (getenv("GLANCEBAR_BAR_DEBUG") && startCollapsed && strcmp(startCollapsed, "1") == 0)
        _barTier.tier = BarTierGlyph;
    _item.button.target = self;
    _item.button.action = @selector(togglePopover:);
    // Re-render immediately when the menu bar flips light/dark (Light/Dark toggle, or a
    // wallpaper change that re-tints the bar). Never removed: _item lives for the whole
    // process, same as this controller.
    [_item.button addObserver:self forKeyPath:@"effectiveAppearance"
                      options:0 context:kBarAppearanceContext];
    // Low Power Mode can change under us (System Settings, Control Center, pmset, the battery
    // dropping low); keep the footer toggle and the bar's yellow battery honest.
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *n) { [self syncPowerButtons]; [self updateBar]; }];

    _popover = [NSPopover new];
    _popover.behavior = NSPopoverBehaviorTransient;
    _popover.animates = YES;
    _popover.delegate = self;   // popoverWillClose: timestamps the dismiss for the toggle guard
    _popover.contentViewController = [NSViewController new];
    _popover.contentViewController.view = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,kW,10)];

    [self refresh];
    // The CPU figure needs two tick samples at least 2 s apart; take the second one now
    // rather than leaving "estimating" on the bar until the 15 s timer first fires.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self refresh]; });
    // Diagnostic: GLANCEBAR_AUTOOPEN=1 opens the popover on launch (for screenshots).
    if (getenv("GLANCEBAR_AUTOOPEN"))
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self togglePopover:nil]; });
    else if (!getenv("GLANCEBAR_SKIP_WELCOME"))
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self showWelcomeIfNeeded]; });
    _musicProbesEnabled = YES;
    [self startNetworkMonitor];
    [self startAudioOutputWatch];
    [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    CFRunLoopSourceRef src = IOPSNotificationCreateRunLoopSource(PSChanged, (__bridge void *)self);
    if (src) {
        CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopDefaultMode);
        CFRelease(src);
    }
}

static void PSChanged(void *ctx) { [(__bridge Controller *)ctx schedulePowerRefresh]; }

- (void)schedulePowerRefresh {
    // IOPS fires on every power-source twitch. One refresh a second covers the burst;
    // the 15s timer still samples on its own cadence.
    if (!ShouldArmPowerRefresh(_powerRefreshPending)) return;
    _powerRefreshPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPowerRefreshCoalesceSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_powerRefreshPending = NO;
        [self refresh];
    });
}

- (dispatch_queue_t)pmsetWorkQueue {
    if (!_pmsetQueue)
        _pmsetQueue = dispatch_queue_create("com.iantodd.glancebar.pmset", DISPATCH_QUEUE_SERIAL);
    return _pmsetQueue;
}

- (void)startAudioOutputWatch {
    _audioDevices = ReadAudioDevices();
    _audioPrevious = _audioDevices;
    _defaultOutputUID = DefaultOutputUID(_audioDevices);
    AudioObjectPropertyAddress devices = AudioAddr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    AudioObjectPropertyAddress output = AudioAddr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &devices, AudioHardwareChanged, (__bridge void *)self);
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &output, AudioHardwareChanged, (__bridge void *)self);
}
- (void)audioDevicesChanged {
    // Bluetooth often publishes an input-only entry, then the output a moment later.
    // Wait until the list stops changing so that late output is still a new device.
    NSUInteger generation = ++_audioSettleGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self->_audioSettleGen) return;
        NSArray<NSDictionary *> *now = ReadAudioDevices();
        NSString *adopt = ChooseNewOutputDevice(self->_audioPrevious, now, SwitchToNewOutputs());
        self->_audioPrevious = now;
        self->_audioDevices = now;
        if (adopt) {
            for (NSDictionary *row in now) {
                if ([row[@"uid"] isEqual:adopt]) { SetOutputDevice((AudioObjectID)[row[@"deviceID"] unsignedIntValue]); break; }
            }
        }
        self->_defaultOutputUID = DefaultOutputUID(now);
        if (self->_popover.isShown) [self rebuildContent];
    });
}
- (void)audioDefaultChanged {
    _defaultOutputUID = DefaultOutputUID(_audioDevices ?: ReadAudioDevices());
    if (!_audioDevices) _audioDevices = ReadAudioDevices();
    if (_popover.isShown) [self rebuildContent];
}
- (void)ensureAudioDisplay {
    if (_audioDevices) return;
    _audioDevices = ReadAudioDevices();
    _defaultOutputUID = DefaultOutputUID(_audioDevices);
}
- (NSInteger)likedCountEstimate {
    NSInteger count = [NSUserDefaults.standardUserDefaults integerForKey:@"youtubeLikedCount"];
    return count > 0 ? count : kYouTubeLikedDefaultCount;
}
- (void)rememberLikedCount:(NSInteger)count {
    if (count < 1) return;
    [NSUserDefaults.standardUserDefaults setInteger:count forKey:@"youtubeLikedCount"];
}
- (void)startNetworkMonitor {
    if (_pathMonitor || !_musicProbesEnabled) return;
    nw_path_monitor_t monitor = nw_path_monitor_create();
    _pathMonitor = monitor;
    nw_path_monitor_set_queue(monitor, dispatch_get_main_queue());
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        BOOL online = nw_path_get_status(path) == nw_path_status_satisfied;
        BOOL changed = !self->_networkKnown || online != self->_networkOnline;
        self->_networkKnown = YES;
        self->_networkOnline = online;
        // Coming back online while the offline player is paused (or finished) has to
        // leave local mode now, or the next Play press is stuck toggling silence.
        if (changed && !online) self->_offlineTracksEntering = YES;
        if (changed && online) [self yieldLocalMusicIfIdle];
        if (changed && self->_popover.isShown) [self rebuildContent];
    });
    nw_path_monitor_start(monitor);
}
- (BOOL)musicOffline {
    if (!_musicProbesEnabled) return NO;
    if (_localMode && !_ytTabOpen) return YES;
    return _networkKnown && !_networkOnline;
}
- (NSArray<NSString *> *)offlineTrackPaths {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL entering = _offlineTracksEntering;
    _offlineTracksEntering = NO;
    NSTimeInterval age = _offlineTracksReady ? now - _offlineTracksAt : 0;
    // Rebuilding the popover used to list the folder every time. Refresh on the way
    // into offline playback, and otherwise at most once a minute.
    if (!OfflineTrackListStale(_offlineTracksReady, entering, age)) return _offlineTracks ?: @[];
    NSString *dir = [GBHomeDirectory() stringByAppendingPathComponent:@"Music/YouTube Liked"];
    NSArray<NSURL *> *urls = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:dir isDirectory:YES]
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *url in urls) if (url.path.length) [paths addObject:url.path];
    _offlineTracks = LikedMusicAudioFiles(paths);
    _offlineTracksAt = CFAbsoluteTimeGetCurrent();
    _offlineTracksReady = YES;
    return _offlineTracks;
}
- (void)publishNowPlaying {
    if (!_localMode) return;
    double elapsed = 0;
    if (_localPlayer.currentTime.timescale != 0) elapsed = CMTimeGetSeconds(_localPlayer.currentTime);
    if (!isfinite(elapsed) || elapsed < 0) elapsed = 0;
    GlanceNowPlayingSet(_localTitle, _localArtist, _localPlayer.rate > 0 ? 1 : 0, elapsed);
}
- (void)enableRemoteCommands {
    if (_remoteCommandsOn) return;
    _remoteCommandsOn = YES;
    GlanceRemoteCommandsEnable(self);
}
- (void)disableRemoteCommands {
    if (!_remoteCommandsOn) return;
    _remoteCommandsOn = NO;
    GlanceRemoteCommandsDisable(self);
}
- (void)applyLocalItemURL:(NSURL *)url {
    NSDictionary *parsed = ParseLikedTrackFilename(url.lastPathComponent);
    _localTitle = parsed[@"title"] ?: @"";
    _localArtist = parsed[@"artist"] ?: @"";
    NSUInteger gen = ++_musicGen;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    [asset loadValuesAsynchronouslyForKeys:@[@"commonMetadata"] completionHandler:^{
        NSString *title = nil, *artist = nil;
        for (AVMetadataItem *item in asset.commonMetadata) {
            if ([item.commonKey isEqual:AVMetadataCommonKeyTitle]) title = item.stringValue;
            if ([item.commonKey isEqual:AVMetadataCommonKeyArtist]) artist = item.stringValue;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_musicGen || !self->_localMode) return;
            if (title.length) self->_localTitle = title;
            if (artist.length) self->_localArtist = artist;
            [self publishNowPlaying];
            if (self->_popover.isShown) [self rebuildContent];
        });
    }];
}
- (void)tearDownLocalPlayer {
    for (AVPlayerItem *item in _localObservedItems)
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    _localObservedItems = nil;
    [_localPlayer pause];
    _localPlayer = nil;
}
// The queue advances by itself and never updates the index, so Next would jump
// backwards and the label would stay on the finished song. At the end, wrap the
// same shuffle and keep going; otherwise the button sits on pause over silence.
- (void)localItemEnded:(NSNotification *)note {
    AVPlayerItem *item = [note.object isKindOfClass:AVPlayerItem.class] ? note.object : nil;
    if (!item) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self advanceAfterLocalItem:item]; });
        return;
    }
    [self advanceAfterLocalItem:item];
}
- (void)advanceAfterLocalItem:(AVPlayerItem *)item {
    if (!_localMode || !_localPlayer || ![_localObservedItems containsObject:item]) return;
    NSInteger next = _localIndex + 1;
    if (next < 0 || next >= (NSInteger)_localURLs.count) {
        [self playLocalIndex:0];
        return;
    }
    _localIndex = next;
    _playbackKnown = YES;
    _playbackPlaying = YES;
    [self applyLocalItemURL:_localURLs[_localIndex]];
    [self publishNowPlaying];
    if (_popover.isShown) [self rebuildContent];
}
- (void)playLocalIndex:(NSInteger)index {
    if (!_localURLs.count) return;
    if (index < 0) index = (NSInteger)_localURLs.count - 1;
    if (index >= (NSInteger)_localURLs.count) index = 0;
    _localIndex = index;
    NSMutableArray<AVPlayerItem *> *items = [NSMutableArray array];
    for (NSInteger i = index; i < (NSInteger)_localURLs.count; i++)
        [items addObject:[AVPlayerItem playerItemWithURL:_localURLs[i]]];
    [self tearDownLocalPlayer];
    _localPlayer = [AVQueuePlayer queuePlayerWithItems:items];
    _localObservedItems = items;
    for (AVPlayerItem *item in items)
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(localItemEnded:) name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    _localMode = YES;
    _localEmpty = NO;
    _playbackKnown = YES;
    _playbackPlaying = YES;
    [self applyLocalItemURL:_localURLs[index]];
    [self enableRemoteCommands];
    [_localPlayer play];
    [self publishNowPlaying];
    if (_popover.isShown) [self rebuildContent];
}
- (void)startOfflinePlayback {
    if (!_musicProbesEnabled) return;
    [self disableRemoteCommands];
    NSArray<NSString *> *paths = [self offlineTrackPaths];
    if (!paths.count) {
        [self tearDownLocalPlayer];
        _localMode = NO;
        _localEmpty = YES;
        _localTitle = nil;
        _localArtist = nil;
        if (_popover.isShown) [self rebuildContent];
        return;
    }
    _localEmpty = NO;
    NSArray<NSString *> *order = ShuffledTrackOrder(paths, arc4random());
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:order.count];
    for (NSString *path in order) [urls addObject:[NSURL fileURLWithPath:path]];
    _localURLs = urls;
    [self playLocalIndex:0];
}
- (void)toggleLocalPlayback {
    if (!_localPlayer) { [self startOfflinePlayback]; return; }
    if (_localPlayer.rate > 0) {
        [_localPlayer pause];
        _playbackPlaying = NO;
    } else {
        [_localPlayer play];
        _playbackPlaying = YES;
    }
    _playbackKnown = YES;
    [self publishNowPlaying];
    if (_popover.isShown) [self rebuildContent];
}
- (void)yieldLocalMusicIfIdle {
    BOOL playing = _localPlayer.rate > 0;
    if (!YieldLocalMusic(_localMode, _networkKnown && _networkOnline, playing)) return;
    [self tearDownLocalPlayer];
    _localMode = NO;
    _localTitle = nil;
    _localArtist = nil;
    _playbackKnown = NO;
    _playbackPlaying = NO;
    [self disableRemoteCommands];
    if (_popover.isShown) [self rebuildContent];
}
- (void)stopLocalForYouTube {
    [self tearDownLocalPlayer];
    _localMode = NO;
    _localEmpty = NO;
    _localTitle = nil;
    _localArtist = nil;
    _playbackKnown = NO;
    _playbackPlaying = NO;
    [self disableRemoteCommands];
}
- (void)beginChromeFallback {
    _musicNote = kYouTubeChromeNote;
    if (_localMode && _localPlayer.rate > 0) {
        if (_popover.isShown) [self rebuildContent];
        return;
    }
    _offlineTracksEntering = YES;
    [self startOfflinePlayback];
}
- (void)startYouTubeProbeTimer {
    if (_ytProbeTimer) return;
    _ytProbeTimer = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(youTubeProbeTimerFired:) userInfo:nil repeats:YES];
}
- (void)stopYouTubeProbeTimer {
    [_ytProbeTimer invalidate];
    _ytProbeTimer = nil;
}
- (void)youTubeProbeTimerFired:(NSTimer *)timer {
    (void)timer;
    if (!_popover.isShown || !_ytTabOpen) { [self stopYouTubeProbeTimer]; return; }
    if (_ytStatusInFlight) return;
    [self runYouTubeStatusAfter:0 generation:_musicGen];
}
- (void)applyYouTubeStatus:(NSDictionary *)status updateTransport:(BOOL)updateTransport {
    NSString *denied = [status[@"denied"] isKindOfClass:NSString.class] ? status[@"denied"] : @"";
    // The hint follows the last script. A later success clears it; it is not a one-shot default.
    if ([denied isEqual:@"javascript"]) {
        _musicNote = kYouTubeJSNote;
        _ytJSDenied = YES;
        _ytTabOpen = YES;
    } else if ([denied isEqual:@"automation"]) {
        _musicNote = kYouTubeAutomationNote;
        _ytJSDenied = NO;
        [self stopYouTubeProbeTimer];
    } else {
        _ytJSDenied = NO;
        if ([_musicNote isEqualToString:kYouTubeJSNote] || [_musicNote isEqualToString:kYouTubeAutomationNote])
            _musicNote = nil;
        BOOL tab = [status[@"tab"] boolValue];
        if (tab) {
            _ytTabOpen = YES;
            if ([_musicNote isEqualToString:kYouTubeChromeNote]) _musicNote = nil;
            if (updateTransport && [status[@"playing"] isKindOfClass:NSNumber.class]) {
                _playbackKnown = YES;
                _playbackPlaying = [status[@"playing"] boolValue];
            }
            // A command's own return can still be the pre-play title. Don't blank a label we have.
            if ([status[@"title"] isKindOfClass:NSString.class] && (updateTransport || [status[@"title"] length] || !_ytTitle.length))
                _ytTitle = status[@"title"];
            if ([status[@"artist"] isKindOfClass:NSString.class] && (updateTransport || [status[@"artist"] length] || !_ytArtist.length))
                _ytArtist = status[@"artist"];
            NSNumber *elapsed = [status[@"elapsed"] isKindOfClass:NSNumber.class] ? status[@"elapsed"] : nil;
            NSNumber *duration = [status[@"duration"] isKindOfClass:NSNumber.class] ? status[@"duration"] : nil;
            if (elapsed || duration) {
                double seconds = elapsed ? elapsed.doubleValue : 0;
                double length = duration ? duration.doubleValue : 0;
                if (!isfinite(seconds) || seconds < 0) seconds = 0;
                _trackElapsed = seconds;
                _trackSampledAt = CFAbsoluteTimeGetCurrent();
                _trackDuration = (isfinite(length) && length > 0) ? length : 0;
            } else {
                _trackElapsed = 0;
                _trackDuration = 0;
                _trackSampledAt = 0;
            }
            NSInteger count = [status[@"count"] integerValue];
            if (count > 0) [self rememberLikedCount:count];
        } else {
            _ytTabOpen = NO;
            _playbackKnown = NO;
            _playbackPlaying = NO;
            _ytTitle = nil;
            _ytArtist = nil;
        }
    }
    // Automation denial has nothing to poll: another tell would just wait on the same dialog.
    if ([denied isEqual:@"automation"] || !_popover.isShown || !_ytTabOpen) [self stopYouTubeProbeTimer];
    else [self startYouTubeProbeTimer];
    if (_popover.isShown) [self rebuildContent];
}
- (void)noteYouTubeScript:(NSString *)output errorText:(NSString *)errorText status:(int)status updateTransport:(BOOL)updateTransport {
    NSDictionary *parsed = ParseYouTubeStatus(output, errorText);
    // A timeout or a launch failure is not "no tab". Leave the last known state alone.
    if ([parsed[@"denied"] isEqual:@""] && ![parsed[@"tab"] boolValue] && status != 0) return;
    [self applyYouTubeStatus:parsed updateTransport:updateTransport];
}
- (void)runYouTubeStatusAfter:(NSTimeInterval)delay generation:(NSUInteger)generation {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self->_musicGen || !self->_musicProbesEnabled) return;
        if (!ChromeIsRunning()) {
            if (self->_ytTabOpen) {
                self->_ytTabOpen = NO;
                self->_playbackKnown = NO;
                [self stopYouTubeProbeTimer];
                if (self->_popover.isShown) [self rebuildContent];
            }
            return;
        }
        // A tell application block launches Chrome when it is not running. Probes must not.
        self->_ytStatusInFlight = YES;
        RunAppleScript(YouTubeControlScript(@"status"), ^(NSString *output, NSString *errorText, int status) {
            self->_ytStatusInFlight = NO;
            if (generation != self->_musicGen) return;
            [self noteYouTubeScript:output errorText:errorText status:status updateTransport:YES];
        });
    });
}
// Retries only while the player bar is missing, so shuffle is clicked once the page is actually there.
- (void)runYouTubeStartGeneration:(NSUInteger)generation delay:(NSTimeInterval)delay attemptsLeft:(NSInteger)attemptsLeft {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self->_musicGen || !self->_musicProbesEnabled || !ChromeIsRunning()) return;
        RunAppleScript(YouTubeControlScript(@"start"), ^(NSString *output, NSString *errorText, int status) {
            if (generation != self->_musicGen) return;
            NSDictionary *parsed = ParseYouTubeStatus(output, errorText);
            BOOL unanswered = [parsed[@"denied"] isEqual:@""] && ![parsed[@"tab"] boolValue] && status != 0;
            if (!unanswered) [self applyYouTubeStatus:parsed updateTransport:YES];
            if ([parsed[@"denied"] isEqual:@"javascript"]) {
                PostSystemMediaKey(NX_KEYTYPE_PLAY);
                return;
            }
            BOOL known = [parsed[@"playing"] isKindOfClass:NSNumber.class] || [parsed[@"title"] length] > 0 || [parsed[@"count"] integerValue] > 0;
            BOOL ready = [parsed[@"tab"] boolValue] && [parsed[@"denied"] isEqual:@""] && known;
            if (!ready && attemptsLeft > 0 && [parsed[@"denied"] isEqual:@""]) {
                NSTimeInterval next = attemptsLeft >= 2 ? 4 : 6;
                [self runYouTubeStartGeneration:generation delay:next attemptsLeft:attemptsLeft - 1];
            } else if (ready) {
                [self runYouTubeStatusAfter:0.3 generation:generation];
            }
        });
    });
}
- (void)playExistingYouTubeTabGeneration:(NSUInteger)generation {
    [self stopLocalForYouTube];
    _ytTabOpen = YES;
    if (_popover.isShown) [self rebuildContent];
    [self runYouTubeStartGeneration:generation delay:0 attemptsLeft:2];
}
- (void)openYouTubeTab {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!YouTubeNewTabAllowed(now, _ytTabOpenedAt)) return;
    NSURL *chrome = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.google.Chrome"];
    NSString *urlString = YouTubeLikedMusicURL(arc4random(), [self likedCountEstimate]);
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || !chrome) { [self beginChromeFallback]; return; }
    _ytTabOpenedAt = now;
    NSUInteger generation = ++_musicGen;
    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.activates = NO;
    [NSWorkspace.sharedWorkspace openURLs:@[url] withApplicationAtURL:chrome configuration:config
                        completionHandler:^(NSRunningApplication *app, NSError *error) {
        (void)app;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_musicGen) return;
            // A failed open must not hold the next Play press off for a minute.
            if (error) { self->_ytTabOpenedAt = 0; [self beginChromeFallback]; return; }
            if ([self->_musicNote isEqualToString:kYouTubeChromeNote]) self->_musicNote = nil;
            [self stopLocalForYouTube];
            self->_ytTabOpen = YES;
            if (self->_popover.isShown) [self rebuildContent];
            [self runYouTubeStartGeneration:generation delay:2 attemptsLeft:2];
        });
    }];
}
- (void)startYouTubePlayback {
    if (!_musicProbesEnabled || _ytStartPending) return;
    NSURL *chrome = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.google.Chrome"];
    if (!chrome) { [self beginChromeFallback]; return; }
    // Chrome is not running, so there is no tab to reuse. openURLs launches it.
    if (!ChromeIsRunning()) { [self openYouTubeTab]; return; }
    _ytStartPending = YES;
    NSUInteger generation = ++_musicGen;
    RunAppleScript(YouTubeControlScript(@"status"), ^(NSString *output, NSString *errorText, int status) {
        self->_ytStartPending = NO;
        if (generation != self->_musicGen) return;
        NSDictionary *parsed = ParseYouTubeStatus(output, errorText);
        if ([parsed[@"denied"] isEqual:@"automation"]) {
            [self applyYouTubeStatus:parsed updateTransport:YES];
            [self openYouTubeTab];
            return;
        }
        if ([parsed[@"tab"] boolValue]) {
            if ([parsed[@"denied"] isEqual:@"javascript"]) {
                [self applyYouTubeStatus:parsed updateTransport:YES];
                PostSystemMediaKey(NX_KEYTYPE_PLAY);
                return;
            }
            [self playExistingYouTubeTabGeneration:generation];
            return;
        }
        if (status != 0) return;
        [self openYouTubeTab];
    });
}
- (NSInteger)remotePlay:(id)event {
    (void)event; if (_localPlayer.rate == 0) [self toggleLocalPlayback];
    return 0;
}
- (NSInteger)remotePause:(id)event {
    (void)event; if (_localPlayer.rate > 0) [self toggleLocalPlayback];
    return 0;
}
- (NSInteger)remoteToggle:(id)event {
    (void)event; [self toggleLocalPlayback]; return 0;
}
- (NSInteger)remoteNext:(id)event {
    (void)event; [self musicNext:nil]; return 0;
}
- (NSInteger)remotePrevious:(id)event {
    (void)event; [self musicPrevious:nil]; return 0;
}
- (void)sendYouTubeCommand:(NSString *)action key:(UInt32)key {
    if (!_musicProbesEnabled) return;
    if (!ChromeIsRunning()) {
        _ytTabOpen = NO;
        _playbackKnown = NO;
        [self stopYouTubeProbeTimer];
        if (_popover.isShown) [self rebuildContent];
        return;
    }
    NSUInteger generation = ++_musicGen;
    // The pill keeps the last probed icon until the follow-up read. play() is async,
    // so the script's own return can still say paused.
    if (_ytJSDenied) {
        PostSystemMediaKey(key);
        [self runYouTubeStatusAfter:0.3 generation:generation];
        return;
    }
    RunAppleScript(YouTubeControlScript(action), ^(NSString *output, NSString *errorText, int status) {
        if (generation != self->_musicGen) return;
        NSDictionary *parsed = ParseYouTubeStatus(output, errorText);
        BOOL unanswered = [parsed[@"denied"] isEqual:@""] && ![parsed[@"tab"] boolValue] && status != 0;
        if ([parsed[@"denied"] isEqual:@"javascript"]) {
            [self applyYouTubeStatus:parsed updateTransport:NO];
            PostSystemMediaKey(key);
        } else if (!unanswered) {
            [self applyYouTubeStatus:parsed updateTransport:NO];
        }
        [self runYouTubeStatusAfter:0.3 generation:generation];
    });
}
- (IBAction)musicPlay:(id)sender {
    (void)sender;
    if (!_musicProbesEnabled) return;
    if (_localMode) { [self toggleLocalPlayback]; return; }
    if (_ytTabOpen) { [self sendYouTubeCommand:@"playpause" key:NX_KEYTYPE_PLAY]; return; }
    if (_networkKnown && !_networkOnline) { [self startOfflinePlayback]; return; }
    [self startYouTubePlayback];
}
- (IBAction)musicPrevious:(id)sender {
    (void)sender;
    if (!_musicProbesEnabled) return;
    if (_localMode) {
        double seconds = CMTimeGetSeconds(_localPlayer.currentTime);
        if (seconds > 3) {
            // The clock ticks from its last sample; restart it with the seek, not 15s later.
            [_localPlayer seekToTime:kCMTimeZero completionHandler:^(BOOL __unused finished) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self noteLocalPlaybackTime]; });
            }];
            _trackElapsed = 0;
            _trackSampledAt = CFAbsoluteTimeGetCurrent();
            return;
        }
        [self playLocalIndex:_localIndex - 1];
        return;
    }
    if (_ytTabOpen) [self sendYouTubeCommand:@"previous" key:NX_KEYTYPE_PREVIOUS];
}
- (IBAction)musicNext:(id)sender {
    (void)sender;
    if (!_musicProbesEnabled) return;
    if (_localMode) { [self playLocalIndex:_localIndex + 1]; return; }
    if (_ytTabOpen) [self sendYouTubeCommand:@"next" key:NX_KEYTYPE_NEXT];
}
- (NSButton *)transportButton:(NSString *)symbol pointSize:(CGFloat)pointSize side:(CGFloat)side
                         action:(SEL)action identifier:(NSString *)identifier label:(NSString *)label {
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:pointSize weight:NSFontWeightSemibold];
    NSImage *image = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
    if (!image) image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:nil];
    NSButton *button = [NSButton buttonWithImage:image target:self action:action];
    button.bordered = NO;
    button.imagePosition = NSImageOnly;
    button.imageScaling = NSImageScaleProportionallyDown;
    button.contentTintColor = NSColor.labelColor;
    button.accessibilityIdentifier = identifier;
    button.accessibilityLabel = label;
    button.frame = NSMakeRect(0, (kSoundH - side) / 2.0, side, side);
    return button;
}
- (void)stopTrackTick {
    [_trackTick invalidate];
    _trackTick = nil;
}
- (void)syncTrackTick {
    BOOL run = _popover.isShown && _playbackPlaying && isfinite(_trackDuration) && _trackDuration > 0;
    if (!run) { [self stopTrackTick]; return; }
    if (_trackTick) return;
    _trackTick = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(trackTick:)
                                                userInfo:nil repeats:YES];
}
// The popover reconciles its view tree in place, so a label captured at build time
// would point at a view that is no longer on screen. Look the subtitle up each tick.
- (void)trackTick:(NSTimer *)timer {
    (void)timer;
    if (!_popover.isShown || !_playbackPlaying) { [self stopTrackTick]; return; }
    NSTextField *subtitle = (NSTextField *)ViewWithAccessibilityIdentifier(
        _popover.contentViewController.view, @"popover.music.subtitle");
    if (![subtitle isKindOfClass:NSTextField.class]) return;
    double elapsed = _trackElapsed;
    if (_trackSampledAt > 0) elapsed += CFAbsoluteTimeGetCurrent() - _trackSampledAt;
    NSString *time = FormatTrackTime(elapsed, _trackDuration);
    if (!time.length) return;
    NSString *artist = _localMode ? _localArtist : _ytArtist;
    subtitle.stringValue = artist.length ? [NSString stringWithFormat:@"%@ · %@", artist, time] : time;
    subtitle.accessibilityLabel = subtitle.stringValue;   // VoiceOver reads the label, not the text
}
- (void)noteLocalPlaybackTime {
    if (!_localPlayer) { _trackDuration = 0; _trackSampledAt = 0; return; }
    CMTime now = _localPlayer.currentTime;
    CMTime length = _localPlayer.currentItem ? _localPlayer.currentItem.duration : kCMTimeInvalid;
    double elapsed = CMTIME_IS_NUMERIC(now) ? CMTimeGetSeconds(now) : 0;
    double duration = CMTIME_IS_NUMERIC(length) ? CMTimeGetSeconds(length) : 0;
    if (!isfinite(elapsed) || elapsed < 0) elapsed = 0;
    _trackElapsed = elapsed;
    _trackSampledAt = CFAbsoluteTimeGetCurrent();
    _trackDuration = (isfinite(duration) && duration > 0) ? duration : 0;
}
- (CGFloat)addMusicControlsTo:(NSView *)root at:(CGFloat)y {
    BOOL offline = [self musicOffline];
    BOOL loaded = _ytTabOpen || _localMode;
    if (_musicProbesEnabled && offline && !_localMode) {
        NSArray *tracks = [self offlineTrackPaths];
        _localEmpty = tracks.count == 0;
    }
    if (_localMode && _localPlayer) {
        [self noteLocalPlaybackTime];
        _playbackKnown = YES;
        _playbackPlaying = _localPlayer.rate > 0;
    }
    NSString *trackTitle = nil, *trackArtist = nil;
    if (_localMode && _localTitle.length) {
        trackTitle = _localTitle;
        trackArtist = _localArtist;
    } else if (!_localMode && _ytTabOpen && _ytTitle.length) {
        trackTitle = _ytTitle;
        trackArtist = _ytArtist;
    }
    NSString *symbol = @"play.fill", *playLabel = @"Play";
    if (loaded) {
        if (!_playbackKnown) { symbol = @"playpause"; playLabel = @"Play or pause"; }
        else if (_playbackPlaying) { symbol = @"pause.fill"; playLabel = @"Pause"; }
    }
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, kSoundH)];
    row.accessibilityIdentifier = @"popover.sound.row";
    CGFloat x = kPad;
    NSButton *prev = [self transportButton:@"backward.end.fill" pointSize:13 side:20
                                    action:@selector(musicPrevious:) identifier:@"popover.music.previous"
                                     label:@"Previous track"];
    prev.frame = NSOffsetRect(prev.frame, x, 0);
    prev.enabled = loaded;
    if (!loaded) prev.contentTintColor = NSColor.tertiaryLabelColor;
    [row addSubview:prev];
    x = NSMaxX(prev.frame) + 2;
    NSButton *play = [self transportButton:symbol pointSize:20 side:28
                                    action:@selector(musicPlay:) identifier:@"popover.music.play" label:playLabel];
    play.frame = NSOffsetRect(play.frame, x, 0);
    [row addSubview:play];
    x = NSMaxX(play.frame) + 2;
    NSButton *next = [self transportButton:@"forward.end.fill" pointSize:13 side:20
                                    action:@selector(musicNext:) identifier:@"popover.music.next" label:@"Next track"];
    next.frame = NSOffsetRect(next.frame, x, 0);
    next.enabled = loaded;
    if (!loaded) next.contentTintColor = NSColor.tertiaryLabelColor;
    [row addSubview:next];
    NSButton *output = [self outputButton];
    output.frame = NSMakeRect(kW - kPad - 22, (kSoundH - 22) / 2.0, 22, 22);
    [row addSubview:output];
    CGFloat textX = NSMaxX(next.frame) + 8;
    CGFloat textW = NSMinX(output.frame) - 8 - textX;
    NSString *titleText = trackTitle.length ? trackTitle : @"Liked Music";
    // The row is a plain NSView, so y grows up; the flipped popover only applies to the root.
    NSTextField *title = [self text:titleText font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]
                              color:nil at:NSMakeRect(textX, 16, textW, 15) align:NSTextAlignmentLeft];
    title.accessibilityIdentifier = @"popover.music.title";
    title.accessibilityLabel = titleText;
    [row addSubview:title];
    double shownElapsed = _trackElapsed;
    if (loaded && _playbackPlaying && _trackSampledAt > 0)
        shownElapsed += CFAbsoluteTimeGetCurrent() - _trackSampledAt;
    NSString *time = loaded ? FormatTrackTime(shownElapsed, _trackDuration) : nil;
    NSString *subtitleText;
    if (!loaded) {
        if (offline && _localEmpty) subtitleText = @"No offline music";
        else if (offline) subtitleText = [NSString stringWithFormat:@"Shuffle · %lu offline",
                                          (unsigned long)[self offlineTrackPaths].count];
        else subtitleText = @"Shuffle · YouTube Music";
    } else if (trackArtist.length && time.length) {
        subtitleText = [NSString stringWithFormat:@"%@ · %@", trackArtist, time];
    } else subtitleText = trackArtist.length ? trackArtist : (time ?: @"");
    NSTextField *subtitle = [self text:subtitleText
                                  font:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]
                                 color:NSColor.secondaryLabelColor
                                    at:NSMakeRect(textX, 2, textW, 14) align:NSTextAlignmentLeft];
    subtitle.accessibilityIdentifier = @"popover.music.subtitle";
    subtitle.accessibilityLabel = subtitleText;
    [row addSubview:subtitle];
    [root addSubview:row];
    return [self addMusicNoteTo:root at:y + kSoundH + 2];
}
- (NSButton *)outputButton {
    [self ensureAudioDisplay];
    NSArray<NSDictionary *> *menu = AudioOutputMenuDevices(_audioDevices, _defaultOutputUID);
    NSDictionary *current = nil;
    for (NSDictionary *row in menu)
        if ([row[@"uid"] isEqual:_defaultOutputUID]) { current = row; break; }
    if (!current)
        for (NSDictionary *row in _audioDevices)
            if ([row[@"uid"] isEqual:_defaultOutputUID]) { current = row; break; }
    NSString *name = current[@"name"] ?: @"No output device";
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightRegular];
    NSImage *image = [[NSImage imageWithSystemSymbolName:AudioSymbolName(current) accessibilityDescription:nil]
                      imageWithSymbolConfiguration:cfg];
    if (!image) image = [NSImage imageWithSystemSymbolName:@"speaker.wave.2" accessibilityDescription:nil];
    OutputCycleButton *button = [OutputCycleButton buttonWithImage:image target:self action:@selector(cycleOutput:)];
    button.bordered = NO;
    button.imagePosition = NSImageOnly;
    button.imageScaling = NSImageScaleProportionallyDown;
    button.contentTintColor = NSColor.secondaryLabelColor;
    button.accessibilityIdentifier = @"popover.sound";
    button.accessibilityLabel = [NSString stringWithFormat:@"Sound output, %@", name];
    NSString *nextUID = NextOutputUID(menu, _defaultOutputUID);
    NSString *nextName = nil;
    for (NSDictionary *row in menu)
        if ([row[@"uid"] isEqual:nextUID]) { nextName = row[@"name"]; break; }
    button.toolTip = nextName.length ? [NSString stringWithFormat:@"%@ — click for %@", name, nextName] : name;
    return button;
}
- (IBAction)cycleOutput:(id)sender {
    NSEvent *event = NSApp.currentEvent;
    BOOL menuGesture = (event.modifierFlags & NSEventModifierFlagOption) ||
        event.type == NSEventTypeRightMouseDown || event.type == NSEventTypeRightMouseUp;
    NSView *anchor = [sender isKindOfClass:NSView.class] ? sender : nil;
    if (menuGesture) { [self showOutputMenu:anchor]; return; }
    NSArray<NSDictionary *> *devices = _audioDevices;
    if (_musicProbesEnabled) {
        devices = ReadAudioDevices();
        _audioDevices = devices;
        NSString *live = DefaultOutputUID(devices);
        if (live.length) _defaultOutputUID = live;
    }
    NSArray<NSDictionary *> *menu = AudioOutputMenuDevices(devices, _defaultOutputUID);
    NSString *next = NextOutputUID(menu, _defaultOutputUID);
    if (!next.length) { [self showOutputMenu:anchor]; return; }
    for (NSDictionary *row in menu) {
        if (![row[@"uid"] isEqual:next]) continue;
        if (_musicProbesEnabled)
            SetOutputDevice((AudioObjectID)[row[@"deviceID"] unsignedIntValue]);
        _defaultOutputUID = next;
        break;
    }
    if (_popover.isShown) [self rebuildContent];
}
- (CGFloat)addMusicNoteTo:(NSView *)root at:(CGFloat)y {
    if (!_musicNote.length) return y;
    NSTextField *hint = [self text:_musicNote font:[NSFont systemFontOfSize:11]
                             color:NSColor.secondaryLabelColor
                                at:NSMakeRect(kPad, y, kW - 2 * kPad, 14) align:NSTextAlignmentLeft];
    hint.maximumNumberOfLines = 1;
    hint.toolTip = _musicNote;
    hint.accessibilityIdentifier = @"popover.music.hint";
    [root addSubview:hint];
    return y + 16;
}
- (void)showOutputMenu:(NSView *)sender {
    [self ensureAudioDisplay];
    NSArray<NSDictionary *> *devices = _audioDevices;
    // Layout tests preset the device list and must not touch CoreAudio.
    if (_musicProbesEnabled) {
        devices = ReadAudioDevices();
        _audioDevices = devices;
        NSString *live = DefaultOutputUID(devices);
        if (live.length) _defaultOutputUID = live;
    }
    NSMenu *menu = [NSMenu new];
    NSArray<NSDictionary *> *items = AudioOutputMenuDevices(devices, _defaultOutputUID);
    if (!items.count) {
        NSMenuItem *empty = [menu addItemWithTitle:@"No output devices" action:nil keyEquivalent:@""];
        empty.enabled = NO;
    }
    for (NSDictionary *device in items) {
        NSMenuItem *item = [menu addItemWithTitle:device[@"name"] ?: @"Output" action:@selector(chooseOutputDevice:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = device[@"uid"];
        item.state = [device[@"uid"] isEqual:_defaultOutputUID] ? NSControlStateValueOn : NSControlStateValueOff;
        item.image = [NSImage imageWithSystemSymbolName:AudioSymbolName(device) accessibilityDescription:nil];
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSMaxY(sender.bounds)) inView:sender];
}
- (void)chooseOutputDevice:(NSMenuItem *)item {
    NSString *uid = item.representedObject;
    if (![uid isKindOfClass:NSString.class]) return;
    for (NSDictionary *row in ReadAudioDevices()) {
        if (![row[@"uid"] isEqual:uid]) continue;
        SetOutputDevice((AudioObjectID)[row[@"deviceID"] unsignedIntValue]);
        _defaultOutputUID = uid;
        break;
    }
    if (_popover.isShown) [self rebuildContent];
}
- (void)toggleSwitchToNewOutputs:(id)sender {
    (void)sender;
    [NSUserDefaults.standardUserDefaults setBool:!SwitchToNewOutputs() forKey:@"switchToNewOutputs"];
}

- (void)refreshVolumesAsync {
    // Each abandoned scan leaves a thread blocked in the kernel; retry a mount that keeps
    // hanging every few minutes, not every tick.
    if (_volumeAbandonedAt > 0 && CFAbsoluteTimeGetCurrent() - _volumeAbandonedAt < 300) return;
    if (_volumesLoading) {
        // The in-flight scan owns the serial queue. Another tick must not enqueue a
        // second one behind it; past the budget the UI says the reading is unavailable.
        if (!_volumesUnavailable &&
            VolumeScanUnavailable(YES, CFAbsoluteTimeGetCurrent() - _volumeScanStarted)) {
            _volumesUnavailable = YES;
            // The stuck call cannot be cancelled. Abandon its queue to it and let the next
            // tick scan on a fresh one, so a mount that recovers is read again.
            _volumeQueue = dispatch_queue_create("com.iantodd.glancebar.volumes", DISPATCH_QUEUE_SERIAL);
            _volumesLoading = NO;
            _volumeAbandonedAt = CFAbsoluteTimeGetCurrent();
            [self updateBar];
            [self refreshVisibleSurfaces];
        }
        return;
    }
    _volumesLoading = YES;
    _volumeScanStarted = CFAbsoluteTimeGetCurrent();
    NSUInteger generation = ++_volumeScanGen;
    dispatch_async(_volumeQueue, ^{
        NSArray<Volume *> *volumes = ScanVolumes();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_volumeScanGen) return;   // an abandoned scan finishing late
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
    BOOL showAI = _popover.isShown || _detailsWindow.isVisible;
    // While every AI surface is hidden, one bounded pass every few minutes keeps the figures
    // warm. Skipping hidden passes entirely meant every open began from whatever the last
    // open left behind, a "Cached limit" from hours ago that read as stuck (2026-10-06).
    if (!showAI && _lastAIRefresh && -_lastAIRefresh.timeIntervalSinceNow < kHiddenAIRefreshInterval) return;
    if (_aiLoading) { _aiRefreshPending = YES; return; }
    _aiLoading = YES;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL useAccount = [ud boolForKey:@"useClaudeAccount"];
    BOOL useCursorAccount = [ud boolForKey:@"useCursorAccount"];
    // Hidden passes are local-only: the account endpoints rate-limit readily, and an open
    // fetches at once when the cache is past its 15 minutes, so a hidden request buys little.
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
            [sig appendFormat:@"%@|%d|%d|%d|%lld|%lld|%lld|%lld|%lld|%lld|%lld|%lld|%.4f|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@;",
             u.name, u.available, u.limitStatusAvailable, u.limitStale,
             u.todayTokens, u.todayTokensAll, u.weekTokens, u.weekTokensAll,
             u.todaySessions, u.weekSessions, u.todayMessages, u.todayToolCalls,
             u.remainingFraction, u.resetText, u.statusText, u.statusReason,
             u.statusSource, u.extraUsage, u.limitWindows, u.models, u.lastActivity,
             u.limitUpdatedAt, u.limitRefreshError, u.billingNote];
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
            else if (needsImmediateRescan && (self->_popover.isShown || self->_detailsWindow.isVisible)) {
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
    Volume *boot = [self primaryVolume];
    return boot ? (int)lround(boot.fraction * 100) : -1;
}

// A cached figure whose window has since reset says nothing about now.
static BOOL AIWindowElapsed(AIUsage *u) {
    return u.limitStale && u.resetAt && u.resetAt.timeIntervalSinceNow <= 0;
}

- (AIUsage *)lowestAIStatus {
    AIUsage *lowest = nil;
    for (AIUsage *u in _aiUsage) {
        if (!u.limitStatusAvailable || u.remainingFraction < 0) continue;
        // A still-current figure from any tool outranks an elapsed cached one, however
        // low the elapsed one reads; among peers the least room wins.
        BOOL elapsed = AIWindowElapsed(u), lowestElapsed = lowest ? AIWindowElapsed(lowest) : YES;
        if (!lowest || (lowestElapsed && !elapsed) ||
            (elapsed == lowestElapsed && u.remainingFraction < lowest.remainingFraction))
            lowest = u;
    }
    return lowest;
}

- (NSString *)aiPercentText:(AIUsage *)u {
    if (!u.limitStatusAvailable || u.remainingFraction < 0) return @"—";
    return [NSString stringWithFormat:@"%d%%", (int)lround(u.remainingFraction * 100)];
}

- (NSColor *)windowColor:(double)frac {
    return AIQuotaColor(frac);
}

// A cached figure older than two poll intervals is not one a refresh would reproduce:
// the number turns amber so the reader does not act on it as current.
- (BOOL)aiSnapshotStaleWarns:(AIUsage *)u {
    if (!u.limitStale || !u.limitUpdatedAt) return NO;
    return StaleSnapshotWarns(-u.limitUpdatedAt.timeIntervalSinceNow, kAccountPollInterval);
}

- (NSColor *)aiStatusColor:(AIUsage *)u {
    if (!u.limitStatusAvailable || u.remainingFraction < 0) return NSColor.tertiaryLabelColor;
    if ([self aiSnapshotStaleWarns:u]) return NSColor.systemOrangeColor;
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
    // Modes are shown by SHAPE, the same glyphs as the footer buttons: the cup for Keep
    // Awake, the tortoise for Low Power (a yellow tint alone was too faint to read).
    NSImage *awakeIcon = GlyphPair(_lidAwake ? TintedSymbol(@"cup.and.saucer.fill", -1, 13, fg) : nil,
                                   LowPowerModeEnabled() ? TintedSymbol(@"tortoise.fill", -1, 13, fg) : nil);
    if (_barShowBattery) {
        NSString *text = _bat.valid ? [NSString stringWithFormat:@"%d%%", _bat.percent] : @"—";
        BOOL lowBattery = _bat.valid && _bat.percent <= 20 && !_bat.acConnected;
        NSColor *color = lowBattery ? BattBarColor(_bat.percent) : fg;
        NSMutableDictionary *seg = [@{@"text": text, @"color": color} mutableCopy];
        if (_bat.valid) {   // no battery (desktop Mac): text-only, no misleading empty glyph
            // The compact tier keeps exactly one high-value reading. Battery percentage
            // wins because macOS may have hidden its own percentage to make room for us.
            seg[@"compactPriority"] = @YES;
            // In the ordinary case the number alone is the densest useful form. Keep the
            // mode glyphs when either mode is on: that reminder outranks width.
            if (!awakeIcon) seg[@"compactTextOnly"] = @YES;
            if (awakeIcon) {
                // A mode is on: swap the battery glyph for its glyph(s) — the footer buttons'
                // icons — an always-visible reminder of settings that persist across reboots.
                // The % stays: battery drain is exactly what you watch while it's forced awake.
                seg[@"image"] = awakeIcon;
                seg[@"keepIcon"] = @YES;   // a reminder, not decoration: survives every tier
                lidAwakeShown = YES;
            } else {
                NSColor *fill = lowBattery ? BattBarColor(_bat.percent) : fg;
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
    // The cup normally rides in the battery segment; if that segment is hidden or there's no
    // battery, still surface a standalone cup so an always-awake Mac never lacks its reminder.
    if (awakeIcon && !lidAwakeShown)
        [segments insertObject:@{@"image": awakeIcon,
                                 @"compactPriority": @YES, @"keepIcon": @YES} atIndex:0];
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
    if (_lidAwake) [parts insertObject:@"Keep Awake on" atIndex:0];
    if (LowPowerModeEnabled()) [parts insertObject:@"Low Power Mode" atIndex:0];
    return parts.count ? [parts componentsJoinedByString:@"; "] : @"Status";
}

// A notched status strip grows left as far as the notch; on a notchless display it
// grows toward the fixed app menus instead. Status hosts to our left can move into
// that free space when we widen; they consume their width, not the whole gap.
// Window bounds/PIDs from CGWindowList carry no TCC gate (names would; we read none)
// and no network — consistent with the README's privacy stance.
//
// macOS 26 hosts the visible status-item window inside Control Centre, with a window
// number unrelated to the app-side NSWindow. Excluding only that number counted our
// own current width as occupied space: Full measured 114pt against its own 115pt
// image, collapsed to Compact, then expanded and repeated forever. Match the hosted
// copy by horizontal geometry and measure the live slot's leftward growth capacity.
static double BarCapacityForWindows(NSArray *list, CGRect displayBounds, double leftBoundary,
                                     BarWindowSpan own, NSInteger ownWindowNumber) {
    double rightEdge = CGRectGetMaxX(displayBounds);
    double menuBarY = CGRectGetMinY(displayBounds);
    double fixedBoundary = leftBoundary;
    CGWindowLevel statusLevel = CGWindowLevelForKey(kCGStatusWindowLevelKey);
    if (![list isKindOfClass:NSArray.class] || list.count == 0) return -1;
    NSMutableData *spanData = [NSMutableData dataWithLength:list.count * sizeof(BarWindowSpan)];
    BarWindowSpan *spans = spanData.mutableBytes;
    size_t spanCount = 0;
    for (NSDictionary *w in list) {
        NSNumber *num = w[(__bridge NSString *)kCGWindowNumber];
        if (num.integerValue == ownWindowNumber) continue;   // our own occupancy is ours to spend
        CGRect b = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)w[(__bridge NSString *)kCGWindowBounds], &b)) continue;
        // The item's own display's menu-bar band. Quartz coordinates put each
        // display's top at CGDisplayBounds.minY, including vertically arranged screens.
        if (fabs(b.origin.y - menuBarY) > 1 || b.size.height > 40) continue;
        // Degenerate 1-px windows (several apps park them at the screen origin) are
        // not status items and do not occupy bar space.
        if (b.size.width < 8 || b.size.height <= 0) continue;
        if (CGRectGetMaxX(b) <= leftBoundary || b.origin.x >= rightEdge) continue;
        NSNumber *layer = w[(__bridge NSString *)kCGWindowLayer];
        if (![layer isKindOfClass:NSNumber.class]) return -1;
        if (layer.integerValue != statusLevel) {
            // A full-display backdrop is not occupied app-menu space. Other windows
            // on our left are fixed, including menus newly intruding into our frame.
            BOOL backdrop = CGRectGetMinX(b) <= CGRectGetMinX(displayBounds) + 1 &&
                            CGRectGetMaxX(b) >= rightEdge - 1;
            if (!backdrop && CGRectGetMinX(b) < own.x)
                fixedBoundary = MAX(fixedBoundary, CGRectGetMaxX(b));
            continue;
        }
        spans[spanCount++] = (BarWindowSpan){b.origin.x, b.size.width};
    }
    // A fixed menu crossing own.x is known crowding, not stale display geometry.
    // Measure the pooled region up to our left edge, then impose the fixed squeeze.
    double boundary = MAX(leftBoundary, MIN(fixedBoundary, own.x));
    double capacity = BarCapacityFromWindowSpans(boundary, rightEdge, own, spans, spanCount);
    return capacity < 0 ? capacity : MIN(capacity, MAX(0.0, own.x + own.width - fixedBoundary));
}

static NSArray<NSString *> *BarRenderedSegmentStrings(NSArray<NSDictionary *> *segments) {
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *seg in segments) {
        id text = seg[@"text"];
        [texts addObject:[text isKindOfClass:NSString.class] ? text : @""];
    }
    return texts;
}

// Displays, the notch, and our own frame — the geometry MeasuredBarCapacity reads
// besides the window list. The list itself is what the 60s bound rechecks.
static NSString *BarScreenConfigurationKey(NSStatusItem *item) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        NSRect frame = screen.frame;
        NSRect aux = screen.auxiliaryTopRightArea;
        id number = screen.deviceDescription[@"NSScreenNumber"] ?: @"?";
        [parts addObject:[NSString stringWithFormat:@"%@ %.1f %.1f %.1f %.1f %.1f %.1f %.1f %.1f",
                          number,
                          frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                          aux.origin.x, aux.origin.y, aux.size.width, aux.size.height]];
    }
    NSWindow *win = item.button.window;
    NSRect itemFrame = win.frame;
    id own = win.screen.deviceDescription[@"NSScreenNumber"] ?: @"-";
    [parts addObject:[NSString stringWithFormat:@"own %@ item %.1f %.1f %.1f %.1f",
                      own, itemFrame.origin.x, itemFrame.origin.y,
                      itemFrame.size.width, itemFrame.size.height]];
    return parts.count ? [parts componentsJoinedByString:@"|"] : nil;
}

static double MeasuredBarCapacity(NSStatusItem *item) {
    NSWindow *win = item.button.window;
    NSScreen *screen = win.screen ?: NSScreen.screens.firstObject;
    if (!screen || !win) return -1;
    NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
    if (![screenNumber isKindOfClass:NSNumber.class]) return -1;
    CGRect displayBounds = CGDisplayBounds((CGDirectDisplayID)screenNumber.unsignedIntValue);
    if (CGRectIsEmpty(displayBounds)) return -1;
    NSRect aux = screen.auxiliaryTopRightArea;
    double leftBoundary = NSWidth(aux) > 0 ? NSMinX(aux) : CGRectGetMinX(displayBounds);
    NSArray *list = CFBridgingRelease(
        CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    BarWindowSpan own = {NSMinX(win.frame), NSWidth(win.frame)};
    return BarCapacityForWindows(list, displayBounds, leftBoundary, own, win.windowNumber);
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
// Whether the bar can be observed at all right now. With the lid closed and the panel
// dark, CGWindowList reports none of this process's own windows — identical to having
// been evicted — and no tier decision can be right or even matter, because nobody is
// looking. Judge the display the item actually lives on, so a clamshell Mac driving an
// external screen still measures normally.
static BOOL BarDisplayObservable(NSStatusItem *item) {
    NSScreen *screen = item.button.window.screen ?: NSScreen.mainScreen;
    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    if (![number isKindOfClass:NSNumber.class]) return NO;
    CGDirectDisplayID display = (CGDirectDisplayID)number.unsignedIntValue;
    return CGDisplayIsActive(display) && !CGDisplayIsAsleep(display);
}

static BOOL BarItemOnBar(NSStatusItem *item) {
    NSWindow *win = item.button.window;
    NSScreen *screen = win.screen ?: NSScreen.screens.firstObject;
    if (!win || !screen) return NO;
    return win.isVisible && NSMaxY(win.frame) >= NSMaxY(screen.frame) - 40;
}

- (NSArray<NSDictionary *> *)barSegmentsForTier:(int)tier full:(NSArray<NSDictionary *> *)full {
    if (tier == BarTierFull) return full;
    if (tier == BarTierText) {
        // Give up the meter icons before giving up any reading: the numbers are what the
        // item is for, and dropping the icons buys roughly a third of the width. A
        // segment with no text of its own (the standalone Keep Awake cup) keeps its icon,
        // and so does any segment that asked to (`keepIcon`) — the cup is a reminder
        // about a setting that persists across reboots, not decoration.
        NSMutableArray *text = [NSMutableArray array];
        for (NSDictionary *seg in full) {
            NSString *label = [seg[@"text"] isKindOfClass:NSString.class] ? seg[@"text"] : nil;
            BOOL keepIcon = [seg[@"keepIcon"] boolValue] || !label.length;
            if (!label.length && !keepIcon) continue;
            NSMutableDictionary *d = [seg mutableCopy];
            if (!keepIcon) {
                [d removeObjectForKey:@"image"];
                [d removeObjectForKey:@"symbol"];
                [d removeObjectForKey:@"var"];
            }
            [d removeObjectForKey:@"compactPriority"];
            [d removeObjectForKey:@"compactTextOnly"];
            [d removeObjectForKey:@"keepIcon"];
            [text addObject:d];
        }
        if (text.count) return text;
    }
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
    // Glyph tier: identity mark — except the Keep Awake cup takes over, so that
    // always-visible reminder survives every tier at zero extra width.
    if (_lidAwake || LowPowerModeEnabled())
        return @[@{@"image": TintedSymbol(_lidAwake ? @"cup.and.saucer.fill" : @"tortoise.fill", -1, 13,
                                          NSColor.controlTextColor)}];
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
        NSArray<NSDictionary *> *tierSegs[kBarTierCount] = {
            full,
            [self barSegmentsForTier:BarTierText full:full],
            [self barSegmentsForTier:BarTierCompact full:full],
            [self barSegmentsForTier:BarTierGlyph full:full],
        };
        double widths[kBarTierCount]; NSArray<NSDictionary *> *draws[kBarTierCount];
        for (int t = 0; t < kBarTierCount; t++) {
            CGFloat w = 0;
            draws[t] = BarLayout(tierSegs[t], fg, &w);
            widths[t] = w;
        }
        // Only a fall FROM the bar is eviction. Before the item has ever been in the
        // bar there is nothing to have been evicted from, so the safety net stays
        // disarmed — otherwise every launch can start at the glyph tier before Control
        // Centre has placed the host window we need for a real capacity measurement.
        // A sleeping display makes every input to this decision untrustworthy, so make
        // no decision: hold the tier and re-measure when the display returns.
        BOOL observable = BarDisplayObservable(self->_item);
        BOOL onBar = observable && BarItemOnBar(self->_item);
        // Before the hosted item is actually on-bar, its app-side frame is not a valid
        // self-exclusion key. Hold the current tier until Control Centre places it.
        // The window list is the expensive read. Skip it while the strings we draw and
        // the screen geometry are the ones we last measured, and never for longer than
        // a minute — neighbours move without changing either.
        double capacity = -1;
        if (onBar) {
            NSString *key = BarCapacityCacheKey(BarRenderedSegmentStrings(full),
                                                BarScreenConfigurationKey(self->_item));
            double now = CFAbsoluteTimeGetCurrent();
            double age = self->_barCapacityMeasuredAt > 0 ? now - self->_barCapacityMeasuredAt
                                                          : kBarCapacityMaxAgeSec;
            if (BarCapacityMeasurementFresh(self->_barCapacityKey, key, age, kBarCapacityMaxAgeSec)) {
                capacity = self->_barCapacityCached;
            } else {
                capacity = MeasuredBarCapacity(self->_item);
                if (key && capacity >= 0) {
                    self->_barCapacityKey = key;
                    self->_barCapacityCached = capacity;
                    self->_barCapacityMeasuredAt = now;
                }
            }
        }
        // The status-item host is wider than its image (16pt on the live Tahoe shell).
        // Price that chrome into every candidate tier or a 115pt image can be judged to
        // fit in 130pt even though its real 131pt host will be evicted. Derive it from
        // the currently installed image, not _barTier: Control Centre resizes the host
        // asynchronously after a tier change, so those two can briefly disagree.
        NSImage *installedImage = self->_item.button.image;
        double hostFrameWidth = NSWidth(self->_item.button.window.frame);
        // After a tier swap the host keeps its OLD width until Control Centre resizes it;
        // measuring chrome against that frame credits the whole width difference to
        // chrome (24pt for battery-only Full→Compact). Wait for the frame to move.
        if (self->_barSwapPending && fabs(hostFrameWidth - self->_barFrameBeforeSwap) > 0.5)
            self->_barSwapPending = NO;
        if (onBar && installedImage && !self->_barSwapPending) {
            double chrome = hostFrameWidth - installedImage.size.width;
            if (isfinite(chrome) && chrome >= 0 && chrome <= 24) {
                self->_barChromeWidth = chrome;
                self->_barChromeKnown = YES;
            }
        }
        double occupiedWidths[kBarTierCount];
        double chrome = self->_barChromeKnown ? self->_barChromeWidth : 0;
        for (int t = 0; t < kBarTierCount; t++) occupiedWidths[t] = widths[t] + chrome;
        if (onBar) self->_barWasOnBar = YES;
        BOOL evicted = BarEvictionSuspected(observable, self->_barWasOnBar, onBar,
                                            CFAbsoluteTimeGetCurrent() - self->_barCreatedAt);
        // The grace counts time the bar was actually observable: a Mac that spent the
        // first minute of its session with the lid shut has not yet had a chance to be
        // placed, and must not be judged as though it had.
        if (!observable) self->_barCreatedAt = CFAbsoluteTimeGetCurrent();
        BarTierState chosen = ChooseBarTier(self->_barTier, capacity, occupiedWidths, evicted,
                                            CFAbsoluteTimeGetCurrent());
        if (getenv("GLANCEBAR_BAR_DEBUG"))
            NSLog(@"bar: capacity=%.0f image=[%.0f %.0f %.0f %.0f] occupied=[%.0f %.0f %.0f %.0f] chrome=%.0f onBar=%d evicted=%d tier %d→%d streak=%d host=[%.0f %.0f]",
                  capacity, widths[0], widths[1], widths[2], widths[3],
                  occupiedWidths[0], occupiedWidths[1], occupiedWidths[2], occupiedWidths[3], chrome,
                  observable ? onBar : -1, evicted,
                  self->_barTier.tier, chosen.tier, chosen.expandStreak,
                  NSMinX(self->_item.button.window.frame), hostFrameWidth);
        self->_barTier = chosen;
        NSImage *next = BarImageFromLayout(draws[chosen.tier], widths[chosen.tier]);
        if (installedImage && fabs(next.size.width - installedImage.size.width) > 0.5) {
            self->_barSwapPending = YES;
            self->_barFrameBeforeSwap = hostFrameWidth;
        }
        self->_item.button.image = next;
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
- (void)refreshLidAwakeAsync { [self refreshLidAwakeForced:NO]; }
// Polled once a minute (other tools can flip the setting); forced right after our own
// toggle, through pmset itself, so the cup follows the change without waiting.
- (void)refreshLidAwakeForced:(BOOL)force {
    if (_lidAwakeReading) return;
    double now = CFAbsoluteTimeGetCurrent();
    if (!force && _lidAwakeLastRead > 0 && now - _lidAwakeLastRead < 60) return;
    _lidAwakeReading = YES;
    _lidAwakeLastRead = now;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSNumber *state = force ? SleepDisabledStateViaTool() : SleepDisabledState();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_lidAwakeReading = NO;
            if (!state) return;   // unknown: keep the last known reading
            BOOL awake = state.boolValue;
            if (awake != self->_lidAwake) { self->_lidAwake = awake; [self syncPowerButtons]; [self updateBar]; }
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
    // Opening the panel is one of the two moments local mode can get out of the way.
    if (_musicProbesEnabled) [self yieldLocalMusicIfIdle];
    [self rebuildContent];
    [_popover showRelativeToRect:_item.button.bounds ofView:_item.button preferredEdge:NSMaxYEdge];
    if (_musicProbesEnabled) [self runYouTubeStatusAfter:0 generation:_musicGen];
    // When the panel is taller than the screen allows it scrolls, and an overlay scroller
    // stays invisible until something scrolls it — so the sections below the fold (AI
    // Status is the last one) look like they do not exist. Flash it on open only: the
    // periodic rebuild would otherwise flash it every 15 seconds.
    [_popoverScroll flashScrollers];
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
    (void)note;
    _popoverClosedAt = CFAbsoluteTimeGetCurrent();
    [self stopYouTubeProbeTimer];
    [self stopTrackTick];
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
// The panel's two controls: a pill that is tinted while its setting is on. Push-on/push-off
// so VoiceOver reports a toggle; the tint is set explicitly because a rounded bezel shows
// no "on" state of its own.
- (NSButton *)powerToggle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    PillButton *b = [PillButton buttonWithTitle:title target:self action:action];
    [b setButtonType:NSButtonTypePushOnPushOff];
    b.bordered = NO;   // PillButton draws the background itself
    b.controlSize = NSControlSizeSmall;
    b.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    b.imagePosition = NSImageLeading;
    b.imageHugsTitle = YES;
    return b;
}
// `ink` is the title/icon colour on the tint: dark on yellow, white on brown.
- (void)styleToggle:(NSButton *)b on:(BOOL)on tint:(NSColor *)tint ink:(NSColor *)ink {
    if (!b) return;   // popover not built yet (a Low Power change can arrive before first open)
    b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    if ([b isKindOfClass:PillButton.class]) ((PillButton *)b).onColor = tint;
    NSColor *color = on ? ink : NSColor.secondaryLabelColor;
    b.contentTintColor = color;
    b.attributedTitle = [[NSAttributedString alloc] initWithString:b.title attributes:@{
        NSFontAttributeName: b.font, NSForegroundColorAttributeName: color}];
    b.needsDisplay = YES;
}
// The footer shows exactly what the menu bar shows, from the same live state: the cup
// while Keep Awake is on, the yellow battery while Low Power is.
- (void)syncPowerButtons {
    if (!_keepAwakeButton || !_lowPowerButton) return;   // popover not built yet
    [self styleToggle:_keepAwakeButton on:_lidAwake tint:NSColor.systemBrownColor ink:NSColor.whiteColor];
    [self styleToggle:_lowPowerButton on:LowPowerModeEnabled() tint:NSColor.systemYellowColor
                  ink:[NSColor colorWithWhite:0.1 alpha:1]];
    // Titles change width with state, so lay the pair out again.
    CGFloat x = kPad - 2;
    for (NSButton *b in @[_keepAwakeButton, _lowPowerButton]) {
        [b sizeToFit];
        b.frame = NSMakeRect(x, 1, b.frame.size.width + 16, 22);   // borderless: add the pill's padding
        x = NSMaxX(b.frame) + 6;
    }
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
    NSString *clock = u.resetAt ? ResetClockText(u.resetAt, NSDate.date) : nil;
    if (clock.length) return [@"Resets " stringByAppendingString:clock];
    NSString *reset = u.resetText ?: @"";
    if (!reset.length || [reset isEqualToString:@"Not exposed locally"] ||
        [reset isEqualToString:@"Not provided"] || [reset isEqualToString:@"Not started"])
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
    // A signed-out account will not refresh on its own; the fix outranks the reset clock,
    // which would otherwise sit beside a figure frozen at the last good fetch.
    if ([u.limitRefreshError hasPrefix:@"Signed out"]) lead = u.limitRefreshError;
    if (!lead.length) lead = u.statusReason;
    // Keep billing visible even when a carried-forward plan window has a reset.
    if ([u.billingNote containsString:@"credits"]) {
        NSString *billing = [u.billingNote containsString:@"none available"] ? @"No credits" : @"Using credits";
        lead = lead.length ? [NSString stringWithFormat:@"%@ · %@", billing, lead] : billing;
    }
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

// A problem replaces the reset clock in the datum column. The full sentence stays
// on the tooltip (aiStatusSubtext / limitRefreshError). Nil means "show the reset".
- (NSString *)aiProblemText:(AIUsage *)u {
    NSString *err = u.limitRefreshError ?: @"";
    if ([err hasPrefix:@"Signed out"]) return @"signed out";
    NSString *blob = [[NSString stringWithFormat:@"%@ %@", err, u.statusReason ?: @""] lowercaseString];
    if ([blob containsString:@"rate-limited"] || [blob containsString:@"rate limited"] ||
        [blob containsString:@"429"])
        return @"rate limited";
    if ([self aiSnapshotStaleWarns:u]) {
        NSString *age = u.limitUpdatedAt ? [self shortAgeForDate:u.limitUpdatedAt] : @"";
        age = [age stringByReplacingOccurrencesOfString:@" ago" withString:@""];
        if (!age.length || [age isEqualToString:@"pending"]) return @"stale";
        return [@"stale " stringByAppendingString:age];
    }
    if (_aiTotalsIncomplete) {
        NSString *status = _aiCatchUpStatus ?: @"";
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"[Ii]ndexing\\s+([0-9]+)%"
                                                                           options:0 error:nil];
        NSTextCheckingResult *match = [re firstMatchInString:status options:0 range:NSMakeRange(0, status.length)];
        if (match.numberOfRanges >= 2)
            return [NSString stringWithFormat:@"indexing %@%%", [status substringWithRange:[match rangeAtIndex:1]]];
        return @"incomplete";
    }
    if (!u.limitStatusAvailable || u.remainingFraction < 0) return @"unavailable";
    return nil;
}

- (NSString *)batteryPopoverTip {
    if (!_bat.valid) return @"No battery detected";
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:[self batteryStatusText]];
    if (_bat.voltage_mV > 0) [parts addObject:[self batteryPowerText]];
    if (_bat.designCap_mAh > 0) {
        int health = (int)lround(100.0 * _bat.rawMax_mAh / _bat.designCap_mAh);
        [parts addObject:[NSString stringWithFormat:@"Health %d%% · %ld cycles", health, (long)_bat.cycleCount]];
    }
    return [parts componentsJoinedByString:@" · "];
}

- (NSString *)batteryDatumText {
    if (!_bat.valid) return @"";
    NSString *datum = @"AC";
    if (!_bat.acConnected) {
        if (_bat.percent <= 20) datum = @"…";
        else {
            int minutes = MinutesTo20(_bat, [self avgAmp]);
            datum = minutes >= 0 ? [NSString stringWithFormat:@"%@ to 20%%", FmtDuration(minutes)] : @"…";
        }
    } else if (_showWatts && _bat.isCharging && _bat.voltage_mV > 0 && _bat.amperage_mA != 0) {
        double watts = fabs((double)_bat.amperage_mA) * _bat.voltage_mV / 1e6;
        datum = [NSString stringWithFormat:@"+%.1f W", watts];
    }
    if (_showHealth && _bat.designCap_mAh > 0 && datum.length) {
        int health = (int)lround(100.0 * _bat.rawMax_mAh / _bat.designCap_mAh);
        NSString *with = [NSString stringWithFormat:@"%@ · %d%%", datum, health];
        NSFont *font = [NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular];
        if ([with sizeWithAttributes:@{NSFontAttributeName: font}].width <= kDatumW - 8) datum = with;   // a label pads its text
    }
    return datum;
}

- (NSAttributedString *)systemReadout {
    NSFont *label = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    NSFont *value = [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightSemibold];
    NSColor *tertiary = NSColor.tertiaryLabelColor;
    NSColor *ink = NSColor.labelColor;
    NSMutableAttributedString *line = [NSMutableAttributedString new];
    void (^add)(NSString *, NSColor *, NSFont *) = ^(NSString *text, NSColor *color, NSFont *font) {
        if (!text.length) return;
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName: font, NSForegroundColorAttributeName: color ?: ink}]];
    };
    add(@"CPU ", tertiary, label);
    add(_sys.cpuValid ? [NSString stringWithFormat:@"%d%%", (int)lround(_sys.cpu * 100)] : @"—", ink, value);
    NSString *level = MemoryPressureLevel(_sys);
    add(@"   MEM ", tertiary, label);
    add(level.lowercaseString, SystemPressureColor(level), value);
    add(@"   SWAP ", tertiary, label);
    NSString *swap = @"—";
    if (_sys.swapValid) swap = _sys.swapUsed == 0 ? @"0 GB" : FmtMemBytes((long long)_sys.swapUsed);
    add(swap, ink, value);
    return line;
}

- (NSImageView *)instrumentSymbol:(NSString *)name tint:(NSColor *)tint identifier:(NSString *)identifier in:(NSView *)row {
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:kLeadSymbol weight:NSFontWeightRegular];
    NSImage *image = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
    if (!image) image = [NSImage imageWithSystemSymbolName:@"questionmark.circle" accessibilityDescription:nil];
    NSImageView *iv = [NSImageView imageViewWithImage:image];
    iv.imageScaling = NSImageScaleProportionallyDown;
    iv.contentTintColor = tint ?: NSColor.secondaryLabelColor;
    iv.frame = NSMakeRect(kPad, (kRowH - kLeadSymbol) / 2.0, kLeadSymbol + 4, kLeadSymbol);
    iv.accessibilityIdentifier = identifier;
    [row addSubview:iv];
    return iv;
}

- (NSTextField *)instrumentValue:(NSString *)text color:(NSColor *)color identifier:(NSString *)identifier in:(NSView *)row {
    NSTextField *field = [self text:text font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                              color:color at:NSMakeRect(kValueX, (kRowH - kValueH) / 2.0, kValueW, kValueH) align:NSTextAlignmentRight];
    field.accessibilityIdentifier = identifier;
    [row addSubview:field];
    return field;
}

- (NSTextField *)instrumentDatum:(NSString *)text color:(NSColor *)color identifier:(NSString *)identifier in:(NSView *)row {
    NSTextField *field = [self text:text ?: @"" font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular]
                              color:color ?: NSColor.secondaryLabelColor
                                 at:NSMakeRect(kDatumX, (kRowH - kDatumH) / 2.0, kDatumW, kDatumH) align:NSTextAlignmentLeft];
    field.accessibilityIdentifier = identifier;
    [row addSubview:field];
    return field;
}

// Claude's row: the gauge and the number are the WEEKLY allowance across all models.
// The 5-hour window stays in the tooltip and Details. A problem (signed out, stale,
// indexing) takes the datum column; the reset clock is the datum otherwise.
- (CGFloat)addAICard:(AIUsage *)u toView:(NSView *)root width:(CGFloat)width pad:(CGFloat)pad at:(CGFloat)y {
    (void)width; (void)pad;
    NSString *name = u.name.length ? u.name : @"AI";
    NSString *slug = name.lowercaseString;
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, kRowH)];
    row.accessibilityIdentifier = [@"popover.row.ai." stringByAppendingString:slug];
    NSDictionary *quotas = [name isEqualToString:@"Claude"] && !u.overageActive && u.limitStatusAvailable
        ? ClaudeModelQuotas(u.limitWindows) : nil;
    double week = quotas ? [quotas[@"opus"] doubleValue] : -1;
    BOOL claudeMeter = quotas != nil;
    BOOL hasGauge = claudeMeter || (u.limitStatusAvailable && u.remainingFraction >= 0);
    NSTextField *title = [self text:name font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]
                              color:nil at:NSMakeRect(kPad, (kRowH - kValueH) / 2.0 - 1, kLeadW, kValueH) align:NSTextAlignmentLeft];
    title.accessibilityIdentifier = [NSString stringWithFormat:@"popover.ai.%@.name", slug];
    [row addSubview:title];

    NSString *pct = @"—";
    NSColor *valueColor = NSColor.tertiaryLabelColor;
    NSString *tip = [self aiStatusSubtext:u] ?: @"";
    if (claudeMeter) {
        pct = week < 0 ? @"—" : [NSString stringWithFormat:@"%.0f%%", week * 100];
        BOOL staleWarns = [self aiSnapshotStaleWarns:u];
        valueColor = staleWarns ? NSColor.systemOrangeColor
            : (week < 0 ? NSColor.tertiaryLabelColor : AIQuotaColor(week));
        NSString *weekClock = [quotas[@"resetsAt"] isKindOfClass:NSNumber.class]
            ? ResetClockText([NSDate dateWithTimeIntervalSince1970:[quotas[@"resetsAt"] doubleValue]], NSDate.date) : nil;
        NSMutableArray *parts = [NSMutableArray arrayWithObject:
            [NSString stringWithFormat:@"This week, all models: %@ left", pct]];
        if (weekClock.length) [parts addObject:[@"Week resets " stringByAppendingString:weekClock]];
        for (NSDictionary *w in u.limitWindows)
            if ([w[@"window"] isEqual:@"5-hour"] && [w[@"remainingFraction"] isKindOfClass:NSNumber.class]) {
                NSString *clock = [w[@"resetsAt"] isKindOfClass:NSNumber.class]
                    ? ResetClockText([NSDate dateWithTimeIntervalSince1970:[w[@"resetsAt"] doubleValue]], NSDate.date) : nil;
                [parts addObject:[NSString stringWithFormat:@"5-hour session: %.0f%% left%@",
                    [w[@"remainingFraction"] doubleValue] * 100,
                    clock.length ? [@", resets " stringByAppendingString:clock] : @""]];
            }
        if (tip.length) [parts addObject:tip];
        tip = [parts componentsJoinedByString:@"\n"];
        ClaudeGauge *meter = [[ClaudeGauge alloc] initWithFrame:NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2.0, kGaugeW, kGaugeH)];
        meter.opus = week;
        meter.accessibilityIdentifier = @"popover.ai.claude.gauge";
        meter.accessibilityLabel = @"Claude weekly allowance remaining, all models";
        meter.toolTip = tip;
        [row addSubview:meter];
    } else if (hasGauge) {
        pct = [self aiPercentText:u];
        valueColor = [self aiStatusColor:u];
        Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2.0, kGaugeW, kGaugeH)];
        g.fraction = u.remainingFraction;
        g.color = valueColor;
        g.metricLabel = [NSString stringWithFormat:@"%@ quota remaining", name];
        g.accessibilityIdentifier = [NSString stringWithFormat:@"popover.ai.%@.gauge", slug];
        g.toolTip = tip;
        [row addSubview:g];
    }
    NSString *valueID = [name isEqualToString:@"Claude"] ? @"popover.claude.value"
        : [NSString stringWithFormat:@"popover.ai.%@.value", slug];
    NSTextField *value = [self instrumentValue:pct color:valueColor identifier:valueID in:row];
    value.toolTip = tip;
    if (claudeMeter) value.accessibilityLabel = @"Percent of the week remaining, all models";
    NSString *problem = [self aiProblemText:u];
    NSColor *datumColor = NSColor.secondaryLabelColor;
    NSString *datum = @"";
    if (problem.length) {
        datum = problem;
        BOOL severe = [problem isEqualToString:@"signed out"] || [problem isEqualToString:@"rate limited"];
        datumColor = severe ? NSColor.systemRedColor : NSColor.systemOrangeColor;
    } else if (!u.overageActive) {
        NSDate *reset = u.resetAt;
        if (claudeMeter && [quotas[@"resetsAt"] isKindOfClass:NSNumber.class])
            reset = [NSDate dateWithTimeIntervalSince1970:[quotas[@"resetsAt"] doubleValue]];
        datum = CompactResetClock(reset, NSDate.date) ?: @"";
    }
    NSTextField *datumField = [self instrumentDatum:datum color:datumColor
                                        identifier:[NSString stringWithFormat:@"popover.ai.%@.datum", slug] in:row];
    datumField.toolTip = tip;
    datumField.accessibilityLabel = tip.length ? tip : datum;
    row.toolTip = tip;
    [root addSubview:row];
    return y + kRowH;
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
    CGFloat y = 8;   // no header row any more; the first instrument starts at the top

    // Machine group. No section labels: the symbol's colour is the state, and the
    // name, the sentence and the breakdown live on the row's tooltip and in Details.
    if (!_vols.count) {
        NSString *status = VolumeScanStatus(_volumesLoading, _volumesUnavailable);
        NSTextField *statusField = [self text:status font:[NSFont systemFontOfSize:12]
                                          color:NSColor.secondaryLabelColor
                                             at:NSMakeRect(kPad, y, kW-2*kPad, 16)
                                          align:NSTextAlignmentLeft];
        statusField.accessibilityIdentifier = @"popover.storage.status";
        [root addSubview:statusField];
        y += kRowH;
    }
    Volume *leadVolume = [self primaryVolume];
    NSMutableArray *fillRows = [NSMutableArray arrayWithCapacity:_vols.count];
    for (Volume *vol in _vols)
        [fillRows addObject:@{@"name": vol.name ?: @"", @"fraction": @(vol.fraction),
                              @"boot": @([vol.path isEqualToString:@"/"])}];
    NSDictionary *secondaryNotice = StorageSecondaryNotice(fillRows);
    if (leadVolume) {
        Volume *v = leadVolume;
        ClickRow *row = [[ClickRow alloc] initWithFrame:NSMakeRect(0, y, kW, kRowH)];
        row.target = self;
        row.action = @selector(showStorageDetails:);
        row.accessibilityRole = NSAccessibilityButtonRole;
        row.accessibilityIdentifier = @"popover.row.storage";
        NSMutableString *tip = [StorageVolumeTooltip(v.name, v.total, v.available, v.purgeable) mutableCopy];
        if ([secondaryNotice[@"text"] isKindOfClass:NSString.class])
            [tip appendFormat:@" · %@", secondaryNotice[@"text"]];
        if (_volumesUnavailable)
            [tip appendFormat:@" · Cached %@ · scan unavailable",
                _lastVolumeSuccess ? [self shortAgeForDate:_lastVolumeSuccess] : @"reading"];
        row.toolTip = tip;
        row.accessibilityLabel = tip;
        // A second mount over 85% full is the alarm: it tints the symbol and is named above.
        NSColor *symbolTint = secondaryNotice ? DiskColor([secondaryNotice[@"fraction"] doubleValue])
                                              : DiskColor(v.fraction);
        [self instrumentSymbol:(v.isInternal ? @"internaldrive" : @"externaldrive")
                         tint:symbolTint identifier:@"popover.storage.symbol" in:row];
        Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2.0, kGaugeW, kGaugeH)];
        g.fraction = v.fraction;
        g.color = DiskColor(v.fraction);
        g.metricLabel = [NSString stringWithFormat:@"%@ storage used", v.name];
        g.accessibilityIdentifier = @"popover.storage.gauge";
        g.toolTip = tip;
        [row addSubview:g];
        NSString *pct = [NSString stringWithFormat:@"%d%%", (int)lround(v.fraction * 100)];
        NSTextField *value = [self instrumentValue:pct color:DiskColor(v.fraction)
                                        identifier:@"popover.storage.value" in:row];
        value.toolTip = tip;
        value.accessibilityLabel = [NSString stringWithFormat:@"%@ percent used", pct];
        NSTextField *datum = [self instrumentDatum:[NSString stringWithFormat:@"%@ free", CompactByteCount(v.available)]
                                            color:NSColor.secondaryLabelColor
                                       identifier:@"popover.storage.datum" in:row];
        datum.toolTip = tip;
        [root addSubview:row];
        y += kRowH;
    }

    {
        ClickRow *row = [[ClickRow alloc] initWithFrame:NSMakeRect(0, y, kW, kRowH)];
        row.target = self;
        row.action = @selector(showBatteryDetails:);
        row.accessibilityRole = NSAccessibilityButtonRole;
        row.accessibilityIdentifier = @"popover.row.battery";
        NSString *tip = [self batteryPopoverTip];
        row.toolTip = tip;
        row.accessibilityLabel = tip;
        if (_bat.valid) {
            [self instrumentSymbol:BatterySymbolName(_bat.percent, _bat.acConnected)
                             tint:BattBarColor(_bat.percent) identifier:@"popover.battery.symbol" in:row];
            Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2.0, kGaugeW, kGaugeH)];
            g.fraction = _bat.percent / 100.0;
            g.color = BattBarColor(_bat.percent);
            g.metricLabel = @"Battery charge";
            g.accessibilityIdentifier = @"popover.battery.gauge";
            g.toolTip = tip;
            [row addSubview:g];
            NSTextField *value = [self instrumentValue:[NSString stringWithFormat:@"%d%%", _bat.percent]
                                                color:BattBarColor(_bat.percent)
                                           identifier:@"popover.battery.value" in:row];
            value.toolTip = tip;
            NSTextField *datum = [self instrumentDatum:[self batteryDatumText] color:NSColor.secondaryLabelColor
                                           identifier:@"popover.battery.datum" in:row];
            datum.toolTip = tip;
        } else {
            [self instrumentSymbol:@"battery.0" tint:NSColor.tertiaryLabelColor
                       identifier:@"popover.battery.symbol" in:row];
            NSTextField *value = [self instrumentValue:@"—" color:NSColor.tertiaryLabelColor
                                           identifier:@"popover.battery.value" in:row];
            value.toolTip = tip;
            [self instrumentDatum:@"" color:nil identifier:@"popover.battery.datum" in:row];
        }
        [root addSubview:row];
        y += kRowH;
    }

    {
        NSString *sysLevel = SystemPressureLevel(_sys);
        NSString *summary = SystemSummaryText(_sys);
        ClickRow *row = [[ClickRow alloc] initWithFrame:NSMakeRect(0, y, kW, kRowH)];
        row.target = self;
        row.action = @selector(showSystemDetails:);
        row.accessibilityRole = NSAccessibilityButtonRole;
        row.accessibilityIdentifier = @"popover.row.system";
        row.toolTip = summary;
        row.accessibilityLabel = summary;
        [self instrumentSymbol:@"cpu" tint:SystemPressureColor(sysLevel)
                   identifier:@"popover.system.symbol" in:row];
        NSTextField *readout = [NSTextField labelWithAttributedString:[self systemReadout]];
        readout.frame = NSMakeRect(kGaugeX, (kRowH - kValueH) / 2.0, kW - kPad - kGaugeX, kValueH);
        readout.lineBreakMode = NSLineBreakByTruncatingTail;
        readout.accessibilityIdentifier = @"popover.system.readout";
        readout.accessibilityLabel = summary;
        readout.toolTip = summary;
        [row addSubview:readout];
        [root addSubview:row];
        y += kRowH;
    }

    y += 8;
    NSBox *soundRule = [self dividerAt:y];
    soundRule.accessibilityIdentifier = @"popover.divider.sound";
    [root addSubview:soundRule];
    y += 8;
    y = [self addMusicControlsTo:root at:y];

    y += 6;
    NSBox *aiRule = [self dividerAt:y];
    aiRule.accessibilityIdentifier = @"popover.divider.ai";
    [root addSubview:aiRule];
    y += 8;
    if (!_aiUsage.count) {
        NSTextField *empty = [self text:@"Limit status unavailable" font:[NSFont systemFontOfSize:12]
                                  color:NSColor.secondaryLabelColor
                                     at:NSMakeRect(kPad, y, kW - 2 * kPad, 16) align:NSTextAlignmentLeft];
        empty.accessibilityIdentifier = @"popover.ai.empty";
        [root addSubview:empty];
        y += kRowH;
    } else {
        for (AIUsage *u in _aiUsage)
            y = [self addAICard:u toView:root width:kW pad:kPad at:y];
    }

    // ---------- fixed footer ----------
    // Keep navigation and freshness visible even when the metric document is
    // taller than the current display and needs to scroll.
    y += 2;
    NSString *freshness = _aiTotalsIncomplete && _aiCatchUpStatus.length
        ? _aiCatchUpStatus
        : [NSString stringWithFormat:@"Checked: machine %@ · AI %@",
           [self shortAgeForDate:_lastMachineRefresh], [self shortAgeForDate:_lastAIRefresh]];
    const CGFloat footerH = 34;
    // Fills windowBackgroundColor in drawRect: instead of freezing it into a CALayer CGColor,
    // so the footer follows a live Light/Dark switch like the panel above it.
    PopoverRootView *footer = [[PopoverRootView alloc] initWithFrame:NSMakeRect(0, 0, kW, footerH)];
    NSBox *footerRule = [self dividerAt:0];
    footerRule.accessibilityIdentifier = @"popover.divider.footer";
    [footer addSubview:footerRule];
    NSView *foot = [[NSView alloc] initWithFrame:NSMakeRect(0, 7, kW, 24)];
    _keepAwakeButton = [self powerToggle:@"Keep Awake" symbol:@"cup.and.saucer.fill"
                                   action:@selector(toggleKeepAwake:)];
    _keepAwakeButton.toolTip = KeepAwakeTooltip(PmsetRuleInstalled());
    _keepAwakeButton.accessibilityIdentifier = @"popover.keepAwake";
    _lowPowerButton = [self powerToggle:@"Low Power" symbol:@"tortoise.fill" action:@selector(toggleLowPowerMode:)];
    _lowPowerButton.toolTip = @"System Low Power Mode.";
    _lowPowerButton.accessibilityIdentifier = @"popover.lowPower";
    [self syncPowerButtons];
    [foot addSubview:_keepAwakeButton];
    [foot addSubview:_lowPowerButton];
    NSButton *more = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"ellipsis.circle"
                                                           accessibilityDescription:@"More"]
                                        target:self action:@selector(showMenu:)];
    more.bordered = NO; more.contentTintColor = NSColor.secondaryLabelColor;
    more.frame = NSMakeRect(kW - kPad - 24, 0, 24, 24);
    more.toolTip = [@"Details, settings and Quit. " stringByAppendingString:freshness];
    more.accessibilityIdentifier = @"popover.more";
    [foot addSubview:more];
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
    [self syncTrackTick];
    if (ReconcileViewTree(previousView, freshView)) {
        _popoverScroll = FirstScrollView(previousView);
        // The outlets were assigned on the discarded fresh tree; point them at the buttons
        // that are actually on screen, or syncPowerButtons styles detached copies.
        NSButton *keepAwake = (NSButton *)ViewWithAccessibilityIdentifier(previousView, @"popover.keepAwake");
        NSButton *lowPower = (NSButton *)ViewWithAccessibilityIdentifier(previousView, @"popover.lowPower");
        if ([keepAwake isKindOfClass:NSButton.class]) _keepAwakeButton = keepAwake;
        if ([lowPower isKindOfClass:NSButton.class]) _lowPowerButton = lowPower;
    } else {
        _popover.contentViewController.view = freshView;
        _popoverScroll = freshScroll;
        [self restoreFocus:focusSnapshot inView:freshView window:popoverWindow];
    }
}

// One short menu off the footer's ⋯: the things you reach for, then everything that is
// set once and left alone tucked into Settings.
- (void)showMenu:(NSButton *)sender {
    NSMenu *m = [NSMenu new];
    NSMenuItem *details = [m addItemWithTitle:@"Details…" action:@selector(showDetails:) keyEquivalent:@""];
    details.target = self;
    NSMenuItem *settings = [m addItemWithTitle:@"Settings" action:nil keyEquivalent:@""];
    settings.submenu = [self settingsMenu];
    NSMenuItem *switchOutputs = [m addItemWithTitle:@"Switch to new outputs" action:@selector(toggleSwitchToNewOutputs:) keyEquivalent:@""];
    switchOutputs.target = self;
    switchOutputs.state = SwitchToNewOutputs() ? NSControlStateValueOn : NSControlStateValueOff;
    [m addItem:NSMenuItem.separatorItem];
    NSMenuItem *about = [m addItemWithTitle:@"About Glancebar" action:@selector(showAbout:) keyEquivalent:@""];
    about.target = self;
    [m addItemWithTitle:@"Quit Glancebar" action:@selector(terminate:) keyEquivalent:@"q"].target = NSApp;
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height) inView:sender];
}
- (void)addSection:(NSMenu *)m title:(NSString *)title {
    if (m.numberOfItems) [m addItem:NSMenuItem.separatorItem];
    if (@available(macOS 14.0, *)) { [m addItem:[NSMenuItem sectionHeaderWithTitle:title]]; return; }
    [m addItemWithTitle:title action:nil keyEquivalent:@""].enabled = NO;
}
- (NSMenuItem *)settingsItem:(NSMenu *)m title:(NSString *)title action:(SEL)action on:(BOOL)on {
    NSMenuItem *item = [m addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}
- (NSMenu *)settingsMenu {
    NSMenu *m = [NSMenu new];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [self addSection:m title:@"Menu bar"];
    [self settingsItem:m title:@"Storage" action:@selector(toggleBarDisk:) on:_barShowDisk];
    [self settingsItem:m title:@"Battery" action:@selector(toggleBarBattery:) on:_barShowBattery];
    [self settingsItem:m title:@"System" action:@selector(toggleBarSystem:) on:_barShowSystem];

    [self addSection:m title:@"Battery"];
    [self settingsItem:m title:@"Current draw" action:@selector(toggleWatts:) on:_showWatts].enabled = _bat.valid;
    [self settingsItem:m title:@"Health" action:@selector(toggleHealth:) on:_showHealth].enabled = _bat.valid;
    [self settingsItem:m title:@"Keep Awake & Low Power without a password" action:@selector(togglePmsetRule:)
                    on:PmsetRuleInstalled()].toolTip = @"Installs or removes a sudoers rule limited to four pmset commands (needs your password once).";

    [self addSection:m title:@"AI status"];
    [self settingsItem:m title:@"Claude transcript token totals" action:@selector(toggleClaudeTranscripts:)
                    on:[ud boolForKey:@"useClaudeTranscripts"]];
    [self settingsItem:m title:@"Claude account via Keychain/API…" action:@selector(toggleClaudeAccount:)
                    on:[ud boolForKey:@"useClaudeAccount"]];
    if (CursorServicePresent(GBHomeDirectory()))
        [self settingsItem:m title:@"Cursor account via local session/API…" action:@selector(toggleCursorAccount:)
                        on:[ud boolForKey:@"useCursorAccount"]];

    [m addItem:NSMenuItem.separatorItem];
    SMAppServiceStatus loginStatus = SMAppService.mainAppService.status;
    NSMenuItem *login = [self settingsItem:m title:loginStatus == SMAppServiceStatusRequiresApproval
                                                    ? @"Launch at Login (approve in System Settings)" : @"Launch at Login"
                                    action:@selector(toggleLaunchAtLogin:) on:loginStatus == SMAppServiceStatusEnabled];
    if (loginStatus == SMAppServiceStatusRequiresApproval) login.state = NSControlStateValueMixed;
    return m;
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
        alert.informativeText = @"Glancebar will read the signed-in Cursor session token from Cursor’s local state database (state.vscdb) and, for the Cursor CLI, from your Keychain through Apple’s /usr/bin/security tool, using whichever is current. It keeps the token only in memory and sends it only to api2.cursor.sh to request your included usage limits, at most every 15 minutes. This relies on Cursor’s private local layout and undocumented account endpoints, so it may stop working after an update.";
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
        alert.informativeText = @"Claude transcript files contain conversation records. Glancebar scans them locally and never sends transcript contents over the network. Its mode-0600 local index stores only file offsets/identity, daily token and activity totals (per model), timestamps, and opaque per-message hashes—not prompts or responses. The same file also keeps the last account usage response when that toggle is on, never a token.";
        [alert addButtonWithTitle:@"Enable Local Scan"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    [ud setBool:enabling forKey:@"useClaudeTranscripts"];
    if (!enabling) dispatch_async(_aiQueue, ^{
        self->_aiReader.allowClaudeTranscripts = NO;
        [self->_aiReader purgeClaudeTranscriptIndex];
    });
    [self refresh];
}
// Keep Awake flips the SleepDisabled system power setting: the only switch that also holds
// a closed lid (a caffeinate-style IOPMAssertion defeats idle sleep only). Nothing is
// stored — the live setting is the single source of truth, so the bar and the button
// always agree however it was last changed. It survives a reboot on its own. Quit clears
// it only when the passwordless sudoers rule is installed (applicationWillTerminate:).
- (void)toggleKeepAwake:(id)s {
    [self syncPowerButtons];   // undo the click's own flip until the system confirms
    NSNumber *current = SleepDisabledState();
    if (!current) {
        // Flipping blind could turn the setting ON when the user meant OFF.
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Couldn’t read the current sleep setting";
        alert.informativeText = @"pmset -g did not answer, so Glancebar can’t tell whether Keep Awake is already on. Try again, or check with `pmset -g | grep SleepDisabled`.";
        [alert runModal];
        return;
    }
    BOOL enabling = !current.boolValue;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if (enabling && ![ud boolForKey:@"keepAwakeExplained"]) {
        NSAlert *alert = [NSAlert new];
        alert.alertStyle = NSAlertStyleInformational;
        alert.messageText = @"Keep this Mac awake?";
        alert.informativeText = PmsetRuleInstalled()
            ? @"Keep Awake stops the Mac sleeping at all—when idle, and with the lid closed (the display still sleeps). Glancebar switches it off when it quits; if it’s left on some other way, a closed Mac can keep running and overheat in a bag, so the cup in the menu bar stays as a reminder."
            : @"Keep Awake stops the Mac sleeping at all—when idle, and with the lid closed (the display still sleeps). Without the one-click setup it needs your password, and Glancebar leaves it on when it quits; a closed Mac can keep running and overheat in a bag, so the cup in the menu bar stays as a reminder.";
        [alert addButtonWithTitle:@"Keep Awake"];
        [alert addButtonWithTitle:@"Cancel"];
        [NSApp activateIgnoringOtherApps:YES];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
        [ud setBool:YES forKey:@"keepAwakeExplained"];
    }
    [self applyPmset:@"disablesleep" on:enabling
            reason:enabling ? @"keep this Mac awake" : @"let this Mac sleep again"
              then:^{
        // pmset rewrites the power plist before it exits, so this read is already current.
        NSNumber *state = SleepDisabledState();
        if (state && state.boolValue != self->_lidAwake) {
            self->_lidAwake = state.boolValue;
            [self syncPowerButtons];
            [self updateBar];
        }
        [self refreshLidAwakeForced:YES];
    }];
}
// Flips system Low Power Mode from the footer toggle. Like the lid toggle, the live system
// state is the only truth: nothing is stored, and a cancelled admin prompt just re-reads
// it so the toggle snaps back.
- (void)toggleLowPowerMode:(id)s {
    BOOL enabling = !LowPowerModeEnabled();
    [self syncPowerButtons];   // undo the click's own flip until the system confirms
    [self applyPmset:@"lowpowermode" on:enabling
            reason:enabling ? @"turn on Low Power Mode" : @"turn off Low Power Mode"
              then:^{ [self syncPowerButtons]; }];
}
// Applies one pmset flag, then runs `then` on the main queue whatever happened (callers
// re-read live state, so a cancel needs no rollback). With the rule installed: `sudo -n`,
// no prompt. Without it: offer the one-time setup once, else the password prompt.
- (void)applyPmset:(NSString *)setting on:(BOOL)on reason:(NSString *)reason then:(dispatch_block_t)then {
    // sudo/osascript run off the main thread. A second click, or quit, must not start
    // another one until this attempt finishes.
    if (!ShouldStartPmset(_pmsetInFlight)) return;
    _pmsetInFlight = YES;
    dispatch_queue_t work = [self pmsetWorkQueue];
    dispatch_block_t finish = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_pmsetInFlight = NO;
            if (then) then();
        });
    };
    NSString *adminPrompt = [NSString stringWithFormat:@"Glancebar needs administrator access to %@.", reason];
    NSString *command = [NSString stringWithFormat:@"/usr/bin/pmset -a %@ %d", setting, on ? 1 : 0];
    if (PmsetRuleInstalled()) {
        dispatch_async(work, ^{
            if (self->_terminating) { finish(); return; }   // never enable as the app quits
            // A rule that no longer matches (edited, or sudo changed) falls back to the prompt.
            if (!RunPmsetViaSudo(setting, on)) SetPmsetShellViaAdmin(command, adminPrompt);
            finish();
        });
        return;
    }
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if (![ud boolForKey:@"pmsetTouchIDOffered"]) {
        [ud setBool:YES forKey:@"pmsetTouchIDOffered"];
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Switch Low Power and Keep Awake without a password?";
        alert.informativeText = @"macOS asks for your administrator password every time these change. Glancebar can instead add a small rule to /etc/sudoers.d that lets your account run just these four commands—pmset lowpowermode 0/1 and disablesleep 0/1—so the switches work with one click. You’ll type your password once to install it. Remove it any time from ⋯ › Settings.";
        [alert addButtonWithTitle:@"Set Up One-Click"];
        [alert addButtonWithTitle:@"Use Password"];
        [NSApp activateIgnoringOtherApps:YES];
        BOOL setUp = [alert runModal] == NSAlertFirstButtonReturn;
        dispatch_async(work, ^{
            // Just authenticated to install, so apply this first change without asking again.
            if (!(setUp && InstallPmsetRule() && RunPmsetViaSudo(setting, on)))
                SetPmsetShellViaAdmin(command, adminPrompt);
            finish();
        });
        return;
    }
    dispatch_async(work, ^{
        SetPmsetShellViaAdmin(command, adminPrompt);
        finish();
    });
}
- (void)togglePmsetRule:(id)s {
    BOOL installed = PmsetRuleInstalled();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (installed) RemovePmsetRule(); else InstallPmsetRule();
    });
}
- (void)toggleWatts:(id)s {
    _showWatts = !_showWatts;
    [NSUserDefaults.standardUserDefaults setBool:_showWatts forKey:@"showWatts"];
    [self rebuildContent];
    if (_detailsWindow.isVisible) [self rebuildDetails];
}
- (void)toggleHealth:(id)s {
    _showHealth = !_showHealth;
    [NSUserDefaults.standardUserDefaults setBool:_showHealth forKey:@"showHealth"];
    [self rebuildContent];
    if (_detailsWindow.isVisible) [self rebuildDetails];
}

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
    alert.informativeText = @"Glancebar now lives in your menu bar. Click its meters for storage, battery, system, and AI status. Keep Awake and Low Power sit at the bottom of the panel; ⋯ › Settings controls what appears and keeps Claude access off until you explicitly enable it. If the item is hidden by a MacBook notch, free one menu-bar slot in Control Center.";
    [alert addButtonWithTitle:@"Got It"];
    [alert addButtonWithTitle:@"Launch at Login"];
    if ([alert runModal] == NSAlertSecondButtonReturn)
        [self setLaunchAtLoginEnabled:YES showErrors:YES];
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
- (Volume *)primaryVolume {
    NSMutableArray<NSNumber *> *boots = [NSMutableArray arrayWithCapacity:_vols.count];
    for (Volume *v in _vols) [boots addObject:@([v.path isEqualToString:@"/"])];
    NSInteger index = StorageHeadlineIndex(boots);
    if (index < 0 || (NSUInteger)index >= _vols.count) return nil;
    return _vols[(NSUInteger)index];
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
            [root addSubview:[self processMetricRow:h right:[NSString stringWithFormat:@"Mem %@", FmtMemBytes(bytes)]
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
        [self addDetailStatus:VolumeScanStatus(_volumesLoading, _volumesUnavailable)
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
        if (volume.purgeable > volume.total / 100)   // worth a line only when it moves the number
            [self addDetailKey:@"Purgeable"
                         value:[NSString stringWithFormat:@"%@ of that · macOS thins it on demand, so Finder counts it as free",
                                FmtBytes(volume.purgeable)]
                            to:root y:&y width:kDetailW];
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
        if (_showWatts)
            [self addDetailKey:@"Power" value:[self batteryPowerText] to:root y:&y width:kDetailW];
        if (!_bat.acConnected && _bat.percent > 20)
            [self addDetailKey:@"Until 20%" value:FmtDuration(MinutesTo20(_bat, [self avgAmp])) to:root y:&y width:kDetailW];
        if (_showHealth && _bat.designCap_mAh > 0) {
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
        NSMutableSet *bucketsListed = [NSMutableSet set];
        for (NSDictionary *w in u.limitWindows) if (w[@"bucket"]) [bucketsListed addObject:w[@"bucket"]];
        for (NSDictionary *w in u.limitWindows) {
            NSNumber *resets = [w[@"resetsAt"] isKindOfClass:NSNumber.class] ? w[@"resetsAt"] : nil;
            NSString *reset = resets ? ResetTextFromDate([NSDate dateWithTimeIntervalSince1970:resets.doubleValue]) : nil;
            int pct = (int)lround([w[@"remainingFraction"] doubleValue] * 100);
            NSString *val = reset.length ? [NSString stringWithFormat:@"%d%% left · resets %@", pct, reset]
                          : [w[@"fresh"] boolValue] ? [NSString stringWithFormat:@"%d%% left · not started", pct]
                          : [NSString stringWithFormat:@"%d%% left", pct];
            NSString *key = bucketsListed.count > 1 && [w[@"bucketLabel"] isKindOfClass:NSString.class]
                ? [NSString stringWithFormat:@"%@ (%@)", w[@"window"], w[@"bucketLabel"]] : w[@"window"];
            [self addDetailKey:key value:val to:root y:&y width:kDetailW];
        }
        if (u.billingNote.length)
            [self addDetailKey:@"Billing" value:u.billingNote to:root y:&y width:kDetailW];
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
            [self addDetailHeading:@"Models · 7 days"
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
            [root addSubview:[self processMetricRow:h right:FmtMemBytes(bytes) fraction:(frac < 1.0 ? frac : 1.0)
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

- (void)showStorageDetails:(id)sender { [self showDetailsTab:@"storage" sender:sender]; }
- (void)showBatteryDetails:(id)sender { [self showDetailsTab:@"battery" sender:sender]; }
- (void)showSystemDetails:(id)sender { [self showDetailsTab:@"system" sender:sender]; }
- (void)showDetailsTab:(NSString *)tab sender:(id)sender {
    [self showDetails:sender];
    if (!tab.length) return;
    for (NSView *view in _detailsWindow.contentView.subviews)
        if ([view isKindOfClass:NSTabView.class])
            [(NSTabView *)view selectTabViewItemWithIdentifier:tab];
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
            @"physicalAvailableBytes": @(volume.physicalAvailable),
            @"purgeableBytes": @(volume.purgeable),
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
    [defaults registerDefaults:@{@"useClaudeAccount": @NO, @"useClaudeTranscripts": @NO,
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
            @"sevenDaySessions": @(item.weekSessions),
            @"todayMessages": @(item.todayMessages),
            @"todayToolCalls": @(item.todayToolCalls),
            @"billingNote": JSONValue(item.billingNote),
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
           FmtMemBytes([system[@"memoryAvailableBytes"] longLongValue])];
    NSString *swap = system[@"swapUsedBytes"] == NSNull.null ? @"Swap unknown"
        : [system[@"swapUsedBytes"] unsignedLongLongValue] == 0 ? @"Swap none"
        : [NSString stringWithFormat:@"Swap %@", FmtMemBytes([system[@"swapUsedBytes"] longLongValue])];
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
            printf("  %6s  %-18s %s\n", UTF8(FmtMemBytes([row[@"bytes"] longLongValue])),
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
        // The JSON's staleness, in words: a cached figure older than the poll interval
        // says its age, the same rule the popover row follows.
        NSString *stale = @"";
        NSDate *checked = provider[@"limitUpdatedAt"] != NSNull.null ? DateFromStatusString(provider[@"limitUpdatedAt"]) : nil;
        if ([provider[@"limitStale"] boolValue]) {
            NSTimeInterval age = checked ? -checked.timeIntervalSinceNow : -1;
            if (!checked) stale = @" · cached";
            else if (age >= kAccountPollInterval)
                stale = age < 3600 ? [NSString stringWithFormat:@" · cached %.0fm ago", age / 60]
                      : age < 86400 ? [NSString stringWithFormat:@" · cached %.0fh ago", age / 3600]
                      : [NSString stringWithFormat:@" · cached %.0fd ago", age / 86400];
        }
        printf("  %-7s %s · %s · today %s · 7d %s%s%s%s\n", UTF8(provider[@"name"]), UTF8(remaining), UTF8(reset),
               UTF8(FmtTokenCount([provider[@"todayFreshTokens"] longLongValue])),
               UTF8(FmtTokenCount([provider[@"sevenDayFreshTokens"] longLongValue])),
               reason.length ? " · " : "", UTF8(reason), UTF8(stale));
        for (NSDictionary *window in provider[@"windows"]) {
            NSString *windowReset = window[@"resetsAt"] ? ResetTextFromDate(
                [NSDate dateWithTimeIntervalSince1970:[window[@"resetsAt"] doubleValue]])
                : [window[@"fresh"] boolValue] ? @"not started" : @"not provided";
            NSString *name = [window[@"bucketLabel"] isKindOfClass:NSString.class]
                ? [NSString stringWithFormat:@"%@ (%@)", window[@"window"], window[@"bucketLabel"]] : window[@"window"];
            printf("          %-18s %d%% left · resets %s\n", UTF8(name),
                   (int)lround([window[@"remainingFraction"] doubleValue] * 100), UTF8(windowReset));
        }
        if (provider[@"billingNote"] != NSNull.null)
            printf("          billing: %s\n", UTF8(provider[@"billingNote"]));
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
        "  --online   Permit the already-opted-in Claude and Cursor account requests.\n",
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
