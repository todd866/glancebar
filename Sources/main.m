// Glancebar — one menu bar item for disk + battery at a glance. Click for a native
// popover with storage per-volume and battery (time-to-20%, energy hogs, draw, health).
// Single-file Objective-C/AppKit. Zero dependencies, no sudo. Pure logic in pure.{h,m}.
#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <libproc.h>
#import <sys/mount.h>
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

#pragma mark - Energy hogs

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

static NSArray<NSDictionary *> *SampleHogs(int topN) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/top"];
    t.arguments = @[@"-l", @"2", @"-s", @"1", @"-stats", @"pid,command,power", @"-o", @"power", @"-n", @"40"];
    NSPipe *pipe = [NSPipe pipe]; t.standardOutput = pipe; t.standardError = [NSPipe pipe];
    if (![t launchAndReturnError:nil]) return @[];
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return ParseHogs(out ?: @"", topN, ^NSString *(pid_t pid){ return AppGroupForPid(pid); });
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

static NSDictionary *BatteryPressureInfo(NSDictionary *h) {
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

static const CGFloat kW = 320, kPad = 16;

@interface Controller : NSObject <NSApplicationDelegate>
@end

@implementation Controller {
    NSStatusItem *_item;
    NSPopover *_popover;
    NSArray<Volume *> *_vols;
    BatteryState _bat;
    NSArray<NSDictionary *> *_hogs;
    NSMutableArray<NSNumber *> *_ampHistory;
    BOOL _showWatts, _showHealth, _hogsLoading, _hogsUnavailable;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud registerDefaults:@{@"showWatts": @YES, @"showHealth": @YES}];
    _showWatts = [ud boolForKey:@"showWatts"];
    _showHealth = [ud boolForKey:@"showHealth"];
    _ampHistory = [NSMutableArray array];
    _hogs = @[];

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
}

- (void)sampleHogsAsync {
    _hogs = @[];
    _hogsLoading = YES;
    _hogsUnavailable = NO;
    if (_popover.isShown) [self rebuildContent];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *hogs = SampleHogs(5);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_hogs = hogs ? hogs : @[];
            self->_hogsLoading = NO;
            self->_hogsUnavailable = self->_hogs.count == 0;
            if (self->_popover.isShown) [self rebuildContent];
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
        for (NSDictionary *h in _hogs) {
            double impact = [h[@"impact"] doubleValue];
            double share = total > 0 ? impact / total : 0;
            NSDictionary *info = BatteryPressureInfo(h);
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

    // ---------- footer ----------
    y += 4;
    [root addSubview:[self dividerAt:y]]; y += 9;
    NSView *foot = [[NSView alloc] initWithFrame:NSMakeRect(0, y, kW, 24)];
    NSButton *opts = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:@"Options"]
                                        target:self action:@selector(showOptions:)];
    opts.bordered = NO; opts.frame = NSMakeRect(kPad-4, 0, 26, 22);
    [foot addSubview:opts];
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
        NSDictionary *info = BatteryPressureInfo(h);
        printf("  %3d%%  %-18s %s\n", (int)lround(share * 100),
               [info[@"title"] UTF8String], [info[@"detail"] UTF8String]);
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
