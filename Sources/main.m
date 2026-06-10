// Glancebar — one menu bar item for disk + battery at a glance. Click for a native
// popover with storage, battery, and system summaries plus a deeper details window.
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
    NSPipe *pipe = [NSPipe pipe]; t.standardOutput = pipe; t.standardError = [NSPipe pipe];
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

#pragma mark - bar image (disk glyph + % + battery glyph + %)

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

// Builds the menu-bar image. Symbols/text use `fg` (the adaptive menu-bar text color)
// except a low battery or near-full disk, whose percentage is tinted to warn.
static NSImage *BarImage(int diskPct, BatteryState b, NSColor *fg) {
    CGFloat pt = 13, gap = 4, pad = 2;
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightRegular];

    double diskFrac = diskPct / 100.0;
    NSColor *diskTxt = diskFrac >= 0.85 ? DiskColor(diskFrac) : fg;
    NSColor *battTxt = b.valid && b.percent <= 20 && !b.acConnected ? BattBarColor(b.percent) : fg;

    NSImage *diskSym = TintedSymbol(@"internaldrive", -1, pt, fg);
    NSString *battName = b.acConnected ? @"battery.100percent.bolt"
                       : b.percent <= 20 ? @"battery.25percent" : @"battery.100percent";
    NSImage *battSym = b.valid ? TintedSymbol(battName, b.percent/100.0, pt, fg) : nil;

    NSString *diskStr = [NSString stringWithFormat:@" %d%%", diskPct];
    NSString *battStr = b.valid ? [NSString stringWithFormat:@" %d%%", b.percent] : @" —";
    NSSize dsz = [diskStr sizeWithAttributes:@{NSFontAttributeName:font}];
    NSSize bsz = [battStr sizeWithAttributes:@{NSFontAttributeName:font}];

    CGFloat h = 18;
    CGFloat w = pad + diskSym.size.width + dsz.width + gap*2
              + (battSym ? battSym.size.width : 0) + bsz.width + pad;
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(ceil(w), h)];
    [img lockFocus];
    CGFloat x = pad, cy;
    cy = (h - diskSym.size.height)/2;
    [diskSym drawAtPoint:NSMakePoint(x, cy) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    x += diskSym.size.width;
    [diskStr drawAtPoint:NSMakePoint(x, (h - dsz.height)/2)
          withAttributes:@{NSFontAttributeName:font, NSForegroundColorAttributeName:diskTxt}];
    x += dsz.width + gap*2;
    if (battSym) {
        cy = (h - battSym.size.height)/2;
        [battSym drawAtPoint:NSMakePoint(x, cy) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        x += battSym.size.width;
    }
    [battStr drawAtPoint:NSMakePoint(x, (h - bsz.height)/2)
          withAttributes:@{NSFontAttributeName:font, NSForegroundColorAttributeName:battTxt}];
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
    NSArray<NSDictionary *> *_hogs;
    NSArray<NSDictionary *> *_topCPU, *_topMem;
    NSMutableArray<NSNumber *> *_ampHistory;
    BOOL _showWatts, _showHealth, _hogsLoading, _hogsUnavailable;
    BOOL _procStatsLoading, _procStatsUnavailable;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud registerDefaults:@{@"showWatts": @YES, @"showHealth": @YES}];
    _showWatts = [ud boolForKey:@"showWatts"];
    _showHealth = [ud boolForKey:@"showHealth"];
    _ampHistory = [NSMutableArray array];
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
    if (_bat.valid) {
        [_ampHistory addObject:@(_bat.amperage_mA)];
        while (_ampHistory.count > 6) [_ampHistory removeObjectAtIndex:0];
    }
    [self updateBar];
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

- (void)updateBar {
    _item.button.image = BarImage([self rootDiskPct], _bat, NSColor.controlTextColor);
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
    y += 20;
    if (_hogs.count == 0) {
        NSString *status = _hogsLoading ? @"measuring…" : (_hogsUnavailable ? @"Unavailable" : @"No active apps");
        [root addSubview:[self text:status font:[NSFont systemFontOfSize:12] color:NSColor.secondaryLabelColor
                               at:NSMakeRect(kPad, y, kW-2*kPad, 16) align:NSTextAlignmentLeft]]; y += 22;
    } else {
        double total = [_hogs.firstObject[@"totalImpact"] doubleValue];
        if (total <= 0) for (NSDictionary *h in _hogs) total += [h[@"impact"] doubleValue];
        NSUInteger shown = 0;
        for (NSDictionary *h in _hogs) {
            if (shown++ >= 3) break;
            double impact = [h[@"impact"] doubleValue];
            double share = total > 0 ? impact / total : 0;
            NSDictionary *info = ProcessDisplayInfo(h);
            NSString *right = [NSString stringWithFormat:@"%@  %d%%", PressureLevel(share), (int)lround(share * 100)];
            NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, 42)];
            CGFloat inner = kW - 2*kPad;
            [row addSubview:[self text:info[@"title"] font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold] color:nil
                                  at:NSMakeRect(kPad, 24, inner-84, 15) align:NSTextAlignmentLeft]];
            [row addSubview:[self text:right
                                  font:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]
                                 color:NSColor.secondaryLabelColor at:NSMakeRect(kW-kPad-82, 24, 82, 15) align:NSTextAlignmentRight]];
            [row addSubview:[self text:info[@"detail"] font:[NSFont systemFontOfSize:10.5] color:NSColor.secondaryLabelColor
                                  at:NSMakeRect(kPad, 9, inner, 13) align:NSTextAlignmentLeft]];
            Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(kPad, 3, inner, 3.5)];
            g.fraction = share;
            g.color = PressureColor(share);
            [row addSubview:g];
            [root addSubview:row]; y += 42;
        }
    }

    if (_showWatts && _bat.valid && _bat.voltage_mV > 0) {
        double watts = fabs((double)_bat.amperage_mA) * _bat.voltage_mV / 1e6;
        NSString *s = _bat.amperage_mA == 0 ? @"Drawing — (on AC)"
            : [NSString stringWithFormat:@"%@ %.1f W", _bat.amperage_mA < 0 ? @"Drawing" : @"Charging at", watts];
        y += 4;
        [root addSubview:[self text:s font:[NSFont systemFontOfSize:12] color:nil
                               at:NSMakeRect(kPad, y, kW-2*kPad, 16) align:NSTextAlignmentLeft]]; y += 19;
    }
    if (_showHealth && _bat.valid && _bat.designCap_mAh > 0) {
        [root addSubview:[self text:[NSString stringWithFormat:@"Health %d%% · %ld/%ld mAh · %ld cycles",
                                     (int)lround(100.0*_bat.rawMax_mAh/_bat.designCap_mAh),
                                     _bat.rawMax_mAh, _bat.designCap_mAh, _bat.cycleCount]
                               font:[NSFont systemFontOfSize:11] color:NSColor.secondaryLabelColor
                                 at:NSMakeRect(kPad, y, kW-2*kPad, 14) align:NSTextAlignmentLeft]]; y += 18;
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
            [root addSubview:[self text:@"Top CPU" font:[NSFont systemFontOfSize:11]
                                  color:NSColor.tertiaryLabelColor at:NSMakeRect(kPad, y, inner, 14) align:NSTextAlignmentLeft]];
            y += 18;
            NSDictionary *h = _topCPU.firstObject;
            double cpu = [h[@"cpu"] doubleValue] / 100.0;
            NSString *right = [NSString stringWithFormat:@"%d%%", (int)lround([h[@"cpu"] doubleValue])];
            [root addSubview:[self processMetricRow:h right:right fraction:(cpu < 1.0 ? cpu : 1.0) color:CPUColor(cpu) at:y]];
            y += 38;
        }
        if (_topMem.count) {
            y += 3;
            [root addSubview:[self text:@"Top memory" font:[NSFont systemFontOfSize:11]
                                  color:NSColor.tertiaryLabelColor at:NSMakeRect(kPad, y, inner, 14) align:NSTextAlignmentLeft]];
            y += 18;
            uint64_t memTotal = _sys.memValid && _sys.memTotal > 0 ? _sys.memTotal : [_topMem.firstObject[@"bytes"] unsignedLongLongValue];
            NSDictionary *h = _topMem.firstObject;
            uint64_t bytes = [h[@"bytes"] unsignedLongLongValue];
            double frac = memTotal > 0 ? (double)bytes / (double)memTotal : 0;
            [root addSubview:[self processMetricRow:h right:FmtBytes(bytes) fraction:(frac < 1.0 ? frac : 1.0)
                                              color:SystemPressureColor(MemoryPressureLevel(_sys)) at:y]];
            y += 38;
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
    _popover.contentSize = NSMakeSize(kW, y);
    _popover.contentViewController.view = root;
}

- (void)showOptions:(NSButton *)sender {
    NSMenu *m = [NSMenu new];
    NSMenuItem *w = [m addItemWithTitle:@"Show current draw" action:@selector(toggleWatts:) keyEquivalent:@""];
    w.target = self; w.state = _showWatts ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *h = [m addItemWithTitle:@"Show battery health" action:@selector(toggleHealth:) keyEquivalent:@""];
    h.target = self; h.state = _showHealth ? NSControlStateValueOn : NSControlStateValueOff;
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height) inView:sender];
}
- (void)toggleWatts:(id)s { _showWatts = !_showWatts; [NSUserDefaults.standardUserDefaults setBool:_showWatts forKey:@"showWatts"]; [self rebuildContent]; }
- (void)toggleHealth:(id)s { _showHealth = !_showHealth; [NSUserDefaults.standardUserDefaults setBool:_showHealth forKey:@"showHealth"]; [self rebuildContent]; }

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
