// Render the real popover offscreen; never launch the app, status item, or samplers.
#import <math.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Watomic-property-with-user-defined-accessor"
#pragma clang diagnostic ignored "-Wunused-parameter"
#define main GlancebarApplicationMain
#import "../Sources/main.m"
#undef main
#pragma clang diagnostic pop
#import "../Tests/offline_fixture.h"
static NSString *gOfflineFixtureHome;
static void CleanupOfflineFixture(void) { if (gOfflineFixtureHome) [NSFileManager.defaultManager removeItemAtPath:gOfflineFixtureHome error:nil]; }

static void PrimeBatteryForecast(Controller *controller, BatteryState battery, BOOL limit80) {
    BatteryForecastTracker *tracker = [BatteryForecastTracker new];
    double now = NSDate.date.timeIntervalSince1970;
    for (int sec=60; sec>=0; sec-=15) [tracker update:battery limit80:limit80 at:now-sec];
    [controller setValue:tracker forKey:@"batteryForecastTracker"];
}
static BOOL ForecastFits(BatteryForecastView *view) {
    if (![view isKindOfClass:BatteryForecastView.class]) return NO;
    NSRect a = [view labelRect:YES], b = [view labelRect:NO];
    NSDictionary *attrs = [view labelAttributes];
    CGFloat gaugeWidth = NSWidth(view.bounds) - 2 * kBatteryForecastSideRoom;
    CGFloat expectedA = kBatteryForecastSideRoom + gaugeWidth * view.forecast.thresholdPercent / 100.0;
    CGFloat expectedB = kBatteryForecastSideRoom + gaugeWidth * view.forecast.endpointPercent / 100.0;
    CGFloat gap = view.forecast.endpointPercent == 0 ? NSMinX(a)-NSMaxX(b) : NSMinX(b)-NSMaxX(a);
    if ([view.thresholdText sizeWithAttributes:attrs].width > NSWidth(a) + 0.01 ||
        [view.endpointText sizeWithAttributes:attrs].width > NSWidth(b) + 0.01 ||
        !NSContainsRect(view.bounds,a) || !NSContainsRect(view.bounds,b) || gap < 1 ||
        fabs(NSMidX(a)-expectedA)>0.01 || fabs(NSMidX(b)-expectedB)>0.01 ||
        view.forecast.thresholdPercent != (view.forecast.endpointPercent == 0 ? 20 : 80)) return NO;
    // Compare with the production gauge, independently of overlay padding and width.
    for (NSView *sibling in view.superview.subviews) {
        if ([sibling isKindOfClass:Gauge.class]) {
            CGFloat origin=NSMinX(sibling.frame), width=NSWidth(sibling.frame);
            if (fabs(NSMinX(view.frame)+NSMidX(a)-(origin+width*view.forecast.thresholdPercent/100.0))>0.01 ||
                fabs(NSMinX(view.frame)+NSMidX(b)-(origin+width*view.forecast.endpointPercent/100.0))>0.01) return NO;
        }
        if ([sibling isKindOfClass:NSTextField.class]) {
            NSTextField *field=(NSTextField *)sibling;
            if (![field.accessibilityIdentifier hasSuffix:@".value"] && ![field.accessibilityIdentifier hasSuffix:@".name"]) continue;
            CGFloat width=[field.stringValue sizeWithAttributes:@{NSFontAttributeName:field.font}].width+4;
            NSRect ink=field.frame;
            if (field.alignment==NSTextAlignmentRight) ink.origin.x=NSMaxX(ink)-width;
            ink.size.width=width;
            if ((view.thresholdText.length && NSIntersectsRect([view convertRect:a toView:view.superview],ink)) ||
                (view.endpointText.length && NSIntersectsRect([view convertRect:b toView:view.superview],ink))) return NO;
        }
    }
    return YES;
}
// The Heat datum as text, each symbol shown as [cpu] / [battery], and the colour of its nth reading.
static NSString *HeatDatumText(NSTextField *field) {
    NSAttributedString *a = field.attributedStringValue;
    NSMutableString *out = [NSMutableString string];
    NSArray *names = @[@"[cpu]", @"[battery]"];
    __block NSUInteger marks = 0;
    [a enumerateAttributesInRange:NSMakeRange(0, a.length) options:0 usingBlock:^(NSDictionary *attrs, NSRange r, __unused BOOL *stop) {
        if (attrs[NSAttachmentAttributeName]) [out appendString:marks < names.count ? names[marks++] : @"[?]"];
        else [out appendString:[a.string substringWithRange:r]];
    }];
    return [out stringByReplacingOccurrencesOfString:@"\u2009" withString:@" "];
}
static NSColor *HeatDatumColor(NSTextField *field, NSUInteger index) {
    NSAttributedString *a = field.attributedStringValue;
    __block NSUInteger seen = 0; __block NSColor *found = nil;
    [a enumerateAttribute:NSForegroundColorAttributeName inRange:NSMakeRange(0, a.length) options:0
               usingBlock:^(id value, NSRange r, BOOL *stop) {
        if (!value || ![[a.string substringWithRange:r] containsString:@"°"]) return;
        if (seen++ == index) { found = value; *stop = YES; }
    }];
    return found;
}

static NSUInteger CountGauges(NSView *view) {
    NSUInteger count = ([view isKindOfClass:Gauge.class] || [view isKindOfClass:QuotaPairGauge.class]) ? 1 : 0;
    for (NSView *child in view.subviews) count += CountGauges(child);
    return count;
}
static QuotaPairGauge *FindClaudeMeter(NSView *view) {
    if ([view isKindOfClass:QuotaPairGauge.class]) return (QuotaPairGauge *)view;
    for (NSView *child in view.subviews) { QuotaPairGauge *m = FindClaudeMeter(child); if (m) return m; }
    return nil;
}
static BOOL HasText(NSView *view, NSString *text) {
    if ([view isKindOfClass:NSTextField.class] && [((NSTextField *)view).stringValue containsString:text]) return YES;
    for (NSView *child in view.subviews) if (HasText(child, text)) return YES;
    return NO;
}
// Recovery of clipped text is required; unsolicited explanatory popups stay off.
// The Next control's hover text is the gesture. Anything else with a tooltip is still a miss.
// A container row that cannot show every volume name, and a host disk that has a
// disk image on it, keep the full names in the row tooltip.
static BOOL KindTileTip(NSView *view) {
    NSString *ident = view.accessibilityIdentifier ?: @"";
    return [ident hasPrefix:@"popover.music.kind."];
}
static BOOL ShowTileTip(NSView *view) {
    NSString *ident = view.accessibilityIdentifier ?: @"";
    return [ident isEqual:@"popover.music.show"] || [ident isEqual:@"popover.mix.station"];
}
static BOOL VolumeNamesTip(NSView *view) {
    NSString *ident = view.accessibilityIdentifier ?: @"";
    if (!view.toolTip.length || ![view.toolTip isEqual:view.accessibilityHelp]) return NO;
    if ([ident hasPrefix:@"popover.row.storage."]) return YES;
    if ([ident hasPrefix:@"details.overview.row.storage."]) return YES;
    return [ident hasPrefix:@"popover.remote."] && [ident containsString:@".volume."];
}
static BOOL IntendedControlTip(NSView *view) {
    if (![view.accessibilityIdentifier isEqual:@"popover.music.next"]) return NO;
    NSString *tip = view.toolTip ?: @"";
    if ([tip isEqual:kMusicNextTip]) return YES;
    // Deck mode keeps this gesture tip and appends the upcoming title.
    NSString *prefix = [kMusicNextTip stringByAppendingString:@" — "];
    return [tip hasPrefix:prefix] && tip.length > prefix.length;
}
static BOOL AppKitTruncatesLabel(NSTextField *field) {
    if (!field.cell || !field.stringValue.length || field.hidden) return NO;
    return !NSIsEmptyRect([field.cell expansionFrameWithFrame:field.bounds inView:field]);
}
static BOOL RecoveryTip(NSView *view) {
    if (![view isKindOfClass:NSTextField.class]) return NO;
    NSTextField *field = (NSTextField *)view;
    return [view.toolTip isEqual:field.stringValue] && AppKitTruncatesLabel(field);
}
static NSView *WordyTip(NSView *view) {
    if (view.toolTip.length && !RecoveryTip(view) && !IntendedControlTip(view) && !VolumeNamesTip(view) &&
        !KindTileTip(view) && !ShowTileTip(view))
        return view;
    for (NSView *child in view.subviews) { NSView *w = WordyTip(child); if (w) return w; }
    return nil;
}
static BOOL HasTip(NSView *view, NSString *text) {
    if ([view.accessibilityHelp containsString:text]) return YES;
    if ([view.accessibilityLabel containsString:text]) return YES;
    for (NSView *child in view.subviews) if (HasTip(child, text)) return YES;
    return NO;
}
static NSUInteger CountIdentifier(NSView *view, NSString *identifier) {
    NSUInteger count = [view.accessibilityIdentifier isEqual:identifier] ? 1 : 0;
    for (NSView *child in view.subviews) count += CountIdentifier(child, identifier);
    return count;
}
static BOOL InstrumentRowsFit(NSView *view) {
    if ([view.accessibilityIdentifier hasPrefix:@"popover.row."] && view.frame.size.height > kRowH + 2) return NO;
    for (NSView *child in view.subviews) if (!InstrumentRowsFit(child)) return NO;
    return YES;
}
static BOOL SameColumn(NSView *a, NSView *b) {
    return a && b && fabs(a.frame.origin.x - b.frame.origin.x) < 0.5;
}
static BOOL SameSize(NSView *a, NSView *b) {
    return a && b && fabs(a.frame.size.width - b.frame.size.width) < 0.5 &&
        fabs(a.frame.size.height - b.frame.size.height) < 0.5;
}
// Separators and section headers are not actionable. A submenu item (Settings) is.
static BOOL ActionableMenuImages(NSMenu *menu) {
    if (!menu) return NO;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.toolTip.length) return NO;
        if (item.isSeparatorItem) continue;
        BOOL actionable = item.action != NULL || item.submenu != nil;
        if (actionable && !item.image) {
            fprintf(stderr, "menu item missing image: %s\n", item.title.UTF8String ?: "");
            return NO;
        }
        if (item.submenu && !ActionableMenuImages(item.submenu)) return NO;
    }
    return YES;
}
static BOOL gStationRender = NO;
static BOOL RenderOffscreen(NSView *view, NSString *path, NSAppearanceName appearance) {
    if (!view || view.bounds.size.width < 1 || view.bounds.size.height < 1 || !path.length) return NO;
    // A detail document does not paint its own window background. On a clear bitmap that
    // leaves light-mode text black-on-black, so composite onto the same fill the window uses.
    NSAppearance *chrome = [NSAppearance appearanceNamed:appearance];
    PopoverRootView *host = [[PopoverRootView alloc] initWithFrame:
        NSMakeRect(0, 0, view.bounds.size.width, view.bounds.size.height)];
    host.appearance = chrome;
    view.appearance = chrome;
    view.frame = host.bounds;
    [host addSubview:view];
    NSBitmapImageRep *rep = getenv("GLANCEBAR_RENDER_1X") ? [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)NSWidth(host.bounds) pixelsHigh:(NSInteger)NSHeight(host.bounds)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0]
        : [host bitmapImageRepForCachingDisplayInRect:host.bounds];
    if (!rep) return NO;
    [host cacheDisplayInRect:host.bounds toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}
static BOOL WriteToneWAV(NSString *path, double hz, double seconds) {
    const int sampleRate = 44100;
    int frames = (int)(sampleRate * seconds + 0.5);
    if (frames < 1) return NO;
    NSMutableData *pcm = [NSMutableData dataWithLength:(NSUInteger)frames * 2];
    int16_t *samples = pcm.mutableBytes;
    for (int i = 0; i < frames; i++) {
        double t = (double)i / sampleRate;
        int16_t s = (int16_t)lrint(0.12 * sin(2.0 * M_PI * hz * t) * 32767.0);
        samples[i] = s;
    }
    uint32_t dataBytes = (uint32_t)pcm.length, riffSize = 36 + dataBytes;
    NSMutableData *wav = [NSMutableData data];
    [wav appendBytes:"RIFF" length:4]; [wav appendBytes:&riffSize length:4]; [wav appendBytes:"WAVE" length:4];
    [wav appendBytes:"fmt " length:4];
    uint32_t fmtSize = 16; [wav appendBytes:&fmtSize length:4];
    uint16_t audioFormat = 1, channels = 1; [wav appendBytes:&audioFormat length:2]; [wav appendBytes:&channels length:2];
    uint32_t rate = (uint32_t)sampleRate; [wav appendBytes:&rate length:4];
    uint32_t byteRate = rate * 2; [wav appendBytes:&byteRate length:4];
    uint16_t blockAlign = 2, bits = 16; [wav appendBytes:&blockAlign length:2]; [wav appendBytes:&bits length:2];
    [wav appendBytes:"data" length:4]; [wav appendBytes:&dataBytes length:4]; [wav appendData:pcm];
    return [wav writeToFile:path atomically:YES];
}
static BOOL Afconvert(NSString *wav, NSString *m4a) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/afconvert"];
    task.arguments = @[@"-f", @"m4af", @"-d", @"aac@22050", wav, m4a];
    if (![task launchAndReturnError:NULL]) return NO;
    [task waitUntilExit];
    return task.terminationStatus == 0 && [NSFileManager.defaultManager fileExistsAtPath:m4a];
}
static NSData *FixtureCoverWidePNG(CGFloat hue) {
    const CGFloat w = 320, h = 180;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedHue:hue saturation:0.65 brightness:0.5 alpha:1]
                                                   endingColor:[NSColor colorWithCalibratedHue:hue + 0.12 saturation:0.45 brightness:0.82 alpha:1]];
    [g drawInRect:NSMakeRect(0, 0, w, h) angle:0];
    [[NSColor whiteColor] setFill];
    [[NSBezierPath bezierPathWithRect:NSMakeRect(20, 40, 80, 50)] fill];
    [NSGraphicsContext restoreGraphicsState];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static NSData *FixtureCoverPNG(CGFloat hue) {
    const CGFloat side = 200;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:side pixelsHigh:side
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedHue:hue saturation:0.65 brightness:0.5 alpha:1]
                                                   endingColor:[NSColor colorWithCalibratedHue:hue + 0.15 saturation:0.45 brightness:0.82 alpha:1]];
    [g drawInRect:NSMakeRect(0, 0, side, side) angle:40];
    [[NSColor whiteColor] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(NSMakeRect(0, 0, side, side), 55, 55)] fill];
    [NSGraphicsContext restoreGraphicsState];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static NSString *FFmpegPath(void) {
    NSString *home = NSHomeDirectory();
    for (NSString *p in @[
            [home stringByAppendingPathComponent:@".local/bin/ffmpeg"],
            @"/opt/homebrew/bin/ffmpeg",
            @"/usr/local/bin/ffmpeg"]) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) return p;
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[ @"-lc", @"command -v ffmpeg" ];
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    if ([task launchAndReturnError:NULL]) {
        [task waitUntilExit];
        if (task.terminationStatus == 0) {
            NSData *d = [[out fileHandleForReading] readDataToEndOfFile];
            NSString *path = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) return path;
        }
    }
    return nil;
}
static BOOL EmbedCoverInM4A(NSString *m4a, NSData *coverPNG) {
    if (!coverPNG.length) return YES;
    NSString *ffmpeg = FFmpegPath();
    if (!ffmpeg.length) return NO;
    NSString *cover = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", NSUUID.UUID.UUIDString]];
    NSString *out = [NSString stringWithFormat:@"%@.embed.m4a", m4a.stringByDeletingPathExtension];
    if (![coverPNG writeToFile:cover atomically:YES]) return NO;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:ffmpeg];
    task.arguments = @[@"-y", @"-loglevel", @"error", @"-i", m4a, @"-i", cover,
                       @"-map", @"0:a", @"-map", @"1:v", @"-c:a", @"copy", @"-c:v", @"mjpeg",
                       @"-disposition:v:0", @"attached_pic", out];
    BOOL ok = NO;
    if ([task launchAndReturnError:NULL]) {
        [task waitUntilExit];
        ok = task.terminationStatus == 0 && [NSFileManager.defaultManager fileExistsAtPath:out];
    }
    if (ok) {
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:m4a error:nil];
        ok = [fm moveItemAtPath:out toPath:m4a error:nil];
    }
    [[NSFileManager defaultManager] removeItemAtPath:cover error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
    return ok;
}
static BOOL WriteSilentM4A(NSString *path, NSString *__unused artist, NSData *coverPNG, double seconds) {
    if (seconds < 0.05) seconds = 0.1;
    NSString *wav = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.wav", NSUUID.UUID.UUIDString]];
    if (!WriteToneWAV(wav, 440, seconds)) return NO;
    if (!Afconvert(wav, path)) {
        [[NSFileManager defaultManager] removeItemAtPath:wav error:nil];
        return NO;
    }
    [[NSFileManager defaultManager] removeItemAtPath:wav error:nil];
    if (coverPNG.length && !EmbedCoverInM4A(path, coverPNG)) return NO;
    return [NSFileManager.defaultManager fileExistsAtPath:path];
}
static BOOL CaptionFits(NSTextField *field) {
    if (![field isKindOfClass:NSTextField.class] || !field.stringValue.length) return YES;
    // AppKit's own answer: a label's cell has an expansion frame only when it truncates its text.
    return NSIsEmptyRect([field.cell expansionFrameWithFrame:field.bounds inView:field]);
}
static BOOL RecoverableLabelOK(NSTextField *field) {
    if (![field isKindOfClass:GBRecoverableTextField.class]) return YES;
    if (AppKitTruncatesLabel(field) && !field.toolTip.length) {
        fprintf(stderr, "clipped recoverable label %s: \"%s\" in %.1fx%.1f\n",
                field.accessibilityIdentifier.UTF8String, field.stringValue.UTF8String,
                field.bounds.size.width, field.bounds.size.height);
        return NO;
    }
    if (AppKitTruncatesLabel(field) && field.toolTip.length && ![field.toolTip isEqual:field.stringValue]) {
        fprintf(stderr, "recoverable label %s tooltip mismatch: \"%s\"\n",
                field.accessibilityIdentifier.UTF8String, field.toolTip.UTF8String);
        return NO;
    }
    return YES;
}
static void DumpClaudeCaption(NSView *view) {   // diagnostics on a width failure
    if ([view isKindOfClass:NSTextField.class] && [view.accessibilityIdentifier isEqual:@"popover.claude.caption"]) {
        NSTextField *f = (NSTextField *)view;
        fprintf(stderr, "caption %.0f/%.0fpt: %s\n",
                [f.stringValue sizeWithAttributes:@{NSFontAttributeName:f.font}].width, f.bounds.size.width - 4,
                f.stringValue.UTF8String);
    }
    for (NSView *child in view.subviews) DumpClaudeCaption(child);
}
static NSView *FindIdentifier(NSView *view, NSString *identifier) {
    if ([view.accessibilityIdentifier isEqual:identifier]) return view;
    for (NSView *child in view.subviews) { NSView *hit = FindIdentifier(child, identifier); if (hit) return hit; }
    return nil;
}
static NSDictionary *ManifestTrackRecord(NSString *path, NSString *tid, NSString *title, NSString *artist) {
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st)) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    uint8_t bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *hash = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) [hash appendFormat:@"%02x", bytes[i]];
    return @{@"id": tid, @"title": title, @"artist": artist, @"album": @"", @"path": path,
             @"sizeBytes": @(st.st_size), @"sha256": hash,
             @"inode": [NSString stringWithFormat:@"%llu", (unsigned long long)st.st_ino],
             @"mtimeNs": [NSString stringWithFormat:@"%lld",
                          (long long)st.st_mtimespec.tv_sec * 1000000000LL + st.st_mtimespec.tv_nsec]};
}
static NSDictionary *MergeOfflineManifest(NSDictionary *base, NSDictionary *extra) {
    NSMutableArray *playlists = [NSMutableArray array];
    if ([base[@"playlists"] isKindOfClass:NSArray.class]) [playlists addObjectsFromArray:base[@"playlists"]];
    if ([extra[@"playlists"] isKindOfClass:NSArray.class]) [playlists addObjectsFromArray:extra[@"playlists"]];
    return @{@"schemaVersion": @1, @"playlists": playlists};
}
static NSDictionary *ManifestReplacingKindHarness(NSDictionary *base, NSDictionary *kindManifest) {
    NSMutableArray *playlists = [NSMutableArray array];
    if ([base[@"playlists"] isKindOfClass:NSArray.class]) {
        for (id item in base[@"playlists"]) {
            if ([item isKindOfClass:NSDictionary.class] && [item[@"key"] isEqual:@"kind:harness"]) continue;
            [playlists addObject:item];
        }
    }
    if ([kindManifest[@"playlists"] isKindOfClass:NSArray.class]) [playlists addObjectsFromArray:kindManifest[@"playlists"]];
    return @{@"schemaVersion": @1, @"playlists": playlists};
}
static NSArray<NSString *> *KindTileIDs(void) { return @[@"dance", @"alt", @"rap", @"chill"]; }
static BOOL MixRowHasLegacySeedTiles(NSView *root) {
    if (FindIdentifier(root, @"popover.mix.newpicks")) return YES;
    for (NSUInteger i = 0; i < 8; i++)
        if (FindIdentifier(root, [NSString stringWithFormat:@"popover.mix.seed.%lu", (unsigned long)i])) return YES;
    return NO;
}
static NSView *KindTileButton(NSView *root, NSString *kind) {
    return FindIdentifier(root, [NSString stringWithFormat:@"popover.music.kind.%@", kind]);
}
static BOOL KindMixRowLayoutOK(NSView *root, NSUInteger tileCount, CGFloat expectedSide) {
    if (MixRowHasLegacySeedTiles(root)) return NO;
    if (tileCount != 5 && tileCount != 6) return NO;
    NSMutableArray<NSView *> *tiles = [NSMutableArray array];
    for (NSString *kind in KindTileIDs()) {
        NSView *t = KindTileButton(root, kind);
        if (!t) return NO;
        [tiles addObject:t];
    }
    if (tileCount == 6) {
        if (!FindIdentifier(root, @"popover.music.show")) return NO;
        [tiles addObject:FindIdentifier(root, @"popover.music.show")];
    } else if (FindIdentifier(root, @"popover.music.show")) return NO;
    NSView *station = FindIdentifier(root, @"popover.mix.station");
    if (!station) return NO;
    [tiles addObject:station];
    CGFloat gap = -1;
    for (NSView *t in tiles) {
        if (fabs(NSWidth(t.frame) - expectedSide) > 0.6 || fabs(NSHeight(t.frame) - expectedSide) > 0.6) return NO;
    }
    if (fabs(NSMinX(tiles.firstObject.frame) - kPad) > 0.6) return NO;
    if (fabs(NSMaxX(tiles.lastObject.frame) - (kW - kPad)) > 0.6) return NO;
    for (NSUInteger i = 1; i < tiles.count; i++) {
        CGFloat g = NSMinX(tiles[i].frame) - NSMaxX(tiles[i - 1].frame);
        if (gap < 0) gap = g;
        else if (fabs(g - gap) > 0.6) return NO;
    }
    return gap >= 0;
}
static BOOL KindTileDetailsOK(NSView *root, NSString *kind, NSString *caption, NSUInteger songs,
                               BOOL playing, BOOL empty) {
    GBKindTile *tile = (GBKindTile *)KindTileButton(root, kind);
    if (![tile isKindOfClass:GBKindTile.class]) return NO;
    if (empty ? (tile.enabled || tile.alphaValue > 0.5) : (!tile.enabled || tile.alphaValue < 0.95)) return NO;
    if (playing ? tile.layer.borderWidth < 1.5 : tile.layer.borderWidth > 0.1) return NO;
    NSView *mark = FindIdentifier(root, [NSString stringWithFormat:@"popover.music.kind.%@.typemark", kind]);
    if (!mark || fabs(mark.frame.origin.y - 3) > 1.5) return NO;
    NSTextField *cap = (NSTextField *)FindIdentifier(root, [NSString stringWithFormat:@"popover.music.kind.%@.caption", kind]);
    NSTextField *cnt = (NSTextField *)FindIdentifier(root, [NSString stringWithFormat:@"popover.music.kind.%@.songs", kind]);
    if (![cap.stringValue isEqual:caption]) return NO;
    NSString *want = songs == 1 ? @"1 song" : [NSString stringWithFormat:@"%lu songs", (unsigned long)songs];
    if (![cnt.stringValue isEqual:want]) return NO;
    if (playing && ![cap.textColor isEqual:NSColor.controlAccentColor]) return NO;
    return YES;
}
static NSDictionary *KindHarnessTracks(NSString *musicDir, BOOL chillOnDisk) {
    NSArray *specs = @[
        @{@"id": @"KD1", @"title": @"Dance One", @"artist": @"Dance Harness", @"genre": @"House", @"kindKey": @"dance", @"hue": @0.08},
        @{@"id": @"KD2", @"title": @"Dance Two", @"artist": @"Dance Harness", @"genre": @"Techno", @"kindKey": @"dance", @"hue": @0.12},
        @{@"id": @"KA1", @"title": @"Alt One", @"artist": @"Alt Harness", @"genre": @"Indie Rock", @"kindKey": @"alt", @"hue": @0.35},
        @{@"id": @"KA2", @"title": @"Alt Two", @"artist": @"Alt Harness", @"genre": @"Alternative", @"kindKey": @"alt", @"hue": @0.40},
        @{@"id": @"KR1", @"title": @"Rap One", @"artist": @"Rap Harness", @"genre": @"Hip-Hop/Rap", @"kindKey": @"rap", @"hue": @0.62},
        @{@"id": @"KR2", @"title": @"Rap Two", @"artist": @"Rap Harness", @"genre": @"Rap", @"kindKey": @"rap", @"hue": @0.66},
        @{@"id": @"KC1", @"title": @"Chill One", @"artist": @"Chill Harness", @"genre": @"Ambient", @"kindKey": @"chill", @"hue": @0.78},
    ];
    NSMutableArray *library = [NSMutableArray array];
    NSMutableArray *records = [NSMutableArray array];
    NSMutableArray *wanted = [NSMutableArray array];
    for (NSDictionary *spec in specs) {
        NSString *path = [musicDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", spec[@"id"]]];
        if (!WriteSilentM4A(path, spec[@"artist"], FixtureCoverPNG([spec[@"hue"] doubleValue]), 0.15)) return nil;
        [library addObject:@{@"id": spec[@"id"], @"title": spec[@"title"], @"artist": spec[@"artist"], @"album": @"",
                             @"genre": spec[@"genre"], @"plays": @8, @"idleDays": @14, @"fav": @NO, @"dislike": @NO,
                             @"year": @2024}];
        BOOL onDisk = ![spec[@"kindKey"] isEqual:@"chill"] || chillOnDisk;
        if (onDisk) {
            NSDictionary *rec = ManifestTrackRecord(path, spec[@"id"], spec[@"title"], spec[@"artist"]);
            if (!rec) return nil;
            [records addObject:rec];
            [wanted addObject:@{@"id": spec[@"id"], @"title": spec[@"title"], @"artist": spec[@"artist"]}];
        }
    }
    NSDictionary *manifest = records.count ? @{@"playlists": @[@{@"key": @"kind:harness", @"requestedTracks": wanted,
        @"requestedTrackIDs": [wanted valueForKey:@"id"], @"tracks": records, @"ready": @YES}]} : @{@"playlists": @[]};
    return @{@"library": library, @"manifest": manifest};
}
static BOOL KindStationCaptionsOK(NSView *root) {
    NSTextField *stCap = (NSTextField *)FindIdentifier(root, @"popover.mix.caption.4");
    NSTextField *stArt = (NSTextField *)FindIdentifier(root, @"popover.mix.artist.4");
    return stCap && stArt && [stCap.stringValue isEqual:@"New music"] && [stArt.stringValue isEqual:@"for you"];
}
static BOOL KindMixRowOK(NSView *root, NSUInteger tileCount, CGFloat side,
                          NSDictionary<NSString *, NSNumber *> *songCounts, NSString *playingKind) {
    if (!KindMixRowLayoutOK(root, tileCount, side) || !FindIdentifier(root, @"popover.mix.station") ||
        !KindStationCaptionsOK(root)) return NO;
    for (NSString *kind in KindTileIDs()) {
        NSUInteger n = [songCounts[kind] unsignedIntegerValue];
        BOOL playing = playingKind.length && [playingKind isEqual:kind];
        if (!KindTileDetailsOK(root, kind, [kind capitalizedString], n, playing, n == 0)) return NO;
    }
    return YES;
}
static BOOL SoundRow(NSView *root, NSString *title, NSString *subtitle, BOOL transportOn) {
    NSTextField *titleField = (NSTextField *)FindIdentifier(root, @"popover.music.title");
    NSTextField *subtitleField = (NSTextField *)FindIdentifier(root, @"popover.music.subtitle");
    NSButton *prev = (NSButton *)FindIdentifier(root, @"popover.music.previous");
    NSButton *play = (NSButton *)FindIdentifier(root, @"popover.music.play");
    NSButton *next = (NSButton *)FindIdentifier(root, @"popover.music.next");
    NSView *output = FindIdentifier(root, @"popover.sound");
    NSView *row = FindIdentifier(root, @"popover.sound.row");
    if (![titleField isKindOfClass:NSTextField.class] || ![titleField.stringValue isEqual:title]) return NO;
    if (![subtitleField isKindOfClass:NSTextField.class] || ![subtitleField.stringValue isEqual:subtitle]) return NO;
    if (![prev isKindOfClass:NSButton.class] || ![play isKindOfClass:NSButton.class] ||
        ![next isKindOfClass:NSButton.class] || !output || !row) return NO;
    if (row.frame.size.height > kSoundH + 2 || CountIdentifier(root, @"popover.sound.row") != 1) return NO;
    if (prev.superview != row || play.superview != row || next.superview != row ||
        titleField.superview != row || subtitleField.superview != row) return NO;
    // The output device has its own line under the track: symbol + name, volume, level.
    NSView *line = FindIdentifier(root, @"popover.sound.line");
    if (!line || output.superview != line || !FindIdentifier(line, @"popover.sound.volume") ||
        !FindIdentifier(line, @"popover.sound.level") || NSMinY(line.frame) < NSMaxY(row.frame) - 0.5) return NO;
    if (prev.enabled != transportOn || next.enabled != transportOn) return NO;
    return FindIdentifier(root, @"popover.sound.chevron") == nil &&
           FindIdentifier(root, @"popover.sound.name") == nil;
}
static BOOL FitsChildren(NSView *view) {
    if ([view isKindOfClass:GBRecoverableTextField.class] && !RecoverableLabelOK((NSTextField *)view)) return NO;
    if (view.toolTip.length && !RecoveryTip(view) && !IntendedControlTip(view) && !VolumeNamesTip(view) &&
        !KindTileTip(view) && !ShowTileTip(view)) {
        fprintf(stderr, "tooltip on %s: %s\n", view.accessibilityIdentifier.UTF8String, view.toolTip.UTF8String);
        return NO;
    }
    for (NSView *child in view.subviews) {
        // AppKit's segmented control has an empty private hosting view before
        // window layout. It paints no content and NSContainsRect rejects empty rects.
        if (NSIsEmptyRect(child.frame)) continue;
        // A hundredth of a point of slack: AppKit sizes a symbol image to 28.000000000000004 in a
        // 28-point view on some display scales, which is rounding, not overflow.
        if (!NSContainsRect(NSInsetRect(view.bounds, -0.01, -0.01), child.frame)) {
            fprintf(stderr, "outside %s (%s) in %s: %s / %s\n", child.accessibilityIdentifier.UTF8String,
                NSStringFromClass(child.class).UTF8String, NSStringFromClass(view.class).UTF8String,
                NSStringFromRect(child.frame).UTF8String, NSStringFromRect(view.bounds).UTF8String);
            return NO;
        }
        if (!FitsChildren(child)) return NO;
        // No cut-off text anywhere: every label's whole string fits its frame.
        if ([child isKindOfClass:NSTextField.class] && !child.hidden && ((NSTextField *)child).maximumNumberOfLines > 1) {
            NSTextField *field = (NSTextField *)child;
            if (AppKitTruncatesLabel(field) && ![field.toolTip isEqual:field.stringValue]) {
                fprintf(stderr, "truncated %s: \"%s\" in %.1fx%.1f high without recovery\n",
                        field.accessibilityIdentifier.UTF8String, field.stringValue.UTF8String,
                        NSWidth(field.bounds), NSHeight(field.bounds));
                return NO;
            }
        } else if ([child isKindOfClass:NSTextField.class] && !child.hidden) {
            NSTextField *field = (NSTextField *)child;
            if (AppKitTruncatesLabel(field)) {
                BOOL recoverable = [field.toolTip isEqual:field.stringValue] && field.lineBreakMode == NSLineBreakByTruncatingTail;
                if (!recoverable) {
                    fprintf(stderr, "truncated %s: \"%s\" in %.1fpt without recovery\n",
                            field.accessibilityIdentifier.UTF8String, field.stringValue.UTF8String,
                            field.bounds.size.width);
                    return NO;
                }
            }
        }
    }
    return YES;
}
static NSColor *MeterPixel(QuotaPairGauge *meter, CGFloat x, CGFloat y) {
    meter.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    NSBitmapImageRep *rep = [meter bitmapImageRepForCachingDisplayInRect:meter.bounds];
    [meter cacheDisplayInRect:meter.bounds toBitmapImageRep:rep];
    return [[rep colorAtX:(NSInteger)(x*rep.pixelsWide/meter.bounds.size.width)
                       y:(NSInteger)(y*rep.pixelsHigh/meter.bounds.size.height)] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
}
static BOOL Red(NSColor *c) { return c && c.redComponent > c.greenComponent + 0.2; }
static BOOL Green(NSColor *c) { return c && c.greenComponent > c.redComponent + 0.2; }
static int Fail(int line) { fprintf(stderr, "Popover check failed at line %d\n", line); return 1; }
static BOOL RenderedImagesDiffer(NSImage *a, NSImage *b) {
    if (!a || !b || a.size.width < 1 || b.size.width < 1) return NO;
    NSInteger w = (NSInteger)llround(MAX(a.size.width, b.size.width) * 2.0);
    NSInteger h = (NSInteger)llround(MAX(a.size.height, b.size.height) * 2.0);
    if (w < 1 || h < 1) return NO;
    if (fabs(a.size.width - b.size.width) > 0.5 || fabs(a.size.height - b.size.height) > 0.5) return YES;
    NSBitmapImageRep *(^rep)(NSImage *) = ^NSBitmapImageRep *(NSImage *image) {
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:ctx];
        [[NSColor blackColor] setFill];
        NSRectFill(NSMakeRect(0, 0, w, h));
        [image drawInRect:NSMakeRect(0, 0, w, h) fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver fraction:1];
        [NSGraphicsContext restoreGraphicsState];
        return bitmap;
    };
    NSBitmapImageRep *ra = rep(a), *rb = rep(b);
    if (!ra.bitmapData || !rb.bitmapData || ra.bytesPerRow != rb.bytesPerRow) return YES;
    return memcmp(ra.bitmapData, rb.bitmapData, (size_t)ra.bytesPerRow * (size_t)h) != 0;
}
static NSView *FirstGauge(NSView *view) {
    if ([view isKindOfClass:Gauge.class] || [view isKindOfClass:QuotaPairGauge.class]) return view;
    for (NSView *child in view.subviews) { NSView *g = FirstGauge(child); if (g) return g; }
    return nil;
}
static BOOL DetailFiller(NSView *view) {
    NSArray *bad = @[@"Not provided", @"Limit status available", @"unknown", @"No local usage"];
    if ([view isKindOfClass:NSTextField.class]) {
        NSString *s = ((NSTextField *)view).stringValue ?: @"";
        for (NSString *phrase in bad) if ([s containsString:phrase]) {
            fprintf(stderr, "detail filler \"%s\" in \"%s\"\n", phrase.UTF8String, s.UTF8String);
            return YES;
        }
    }
    for (NSView *child in view.subviews) if (DetailFiller(child)) return YES;
    return NO;
}
static NSView *FindInDocs(NSArray<NSView *> *docs, NSString *identifier) {
    for (NSView *doc in docs) {
        NSView *hit = FindIdentifier(doc, identifier);
        if (hit) return hit;
    }
    return nil;
}
static BOOL DetailColumnsMatch(NSArray<NSView *> *docs) {
    NSArray *values = @[
        @"details.overview.storage.value",
        @"details.overview.battery.value",
        @"details.overview.ai.claude.value",
        @"details.storage.row.0.value",
        @"details.battery.charge.value",
        @"details.battery.health.value",
        @"details.system.cpu.value",
        @"details.system.memory.value",
        @"details.system.swap.value",
        @"details.ai.claude.value",
        @"details.ai.codex.value",
        @"details.ai.history.claude.value",
    ];
        NSView *anchor = nil;
        for (NSString *ident in values) {
            NSView *field = FindInDocs(docs, ident);
            if (!field) { fprintf(stderr, "missing value column %s\n", ident.UTF8String); return NO; }
        if (!anchor) anchor = field;
        else if (!SameColumn(anchor, field)) {
            fprintf(stderr, "value x %.1f vs %.1f (%s)\n", anchor.frame.origin.x, field.frame.origin.x, ident.UTF8String);
            return NO;
        }
    }
    NSArray *gauges = @[
        @"details.overview.storage.gauge",
        @"details.overview.battery.gauge",
        @"details.overview.ai.claude.gauge",
        @"details.battery.charge.gauge",
        @"details.battery.health.gauge",
        @"details.system.cpu.gauge",
        @"details.system.memory.gauge",
        @"details.ai.claude.gauge",
        @"details.ai.codex.gauge",
    ];
        NSView *gaugeAnchor = nil;
        for (NSString *ident in gauges) {
            NSView *gauge = FindInDocs(docs, ident);
            if (!gauge) { fprintf(stderr, "missing gauge %s\n", ident.UTF8String); return NO; }
        if (!gaugeAnchor) gaugeAnchor = gauge;
        else if (!SameColumn(gaugeAnchor, gauge) || !SameSize(gaugeAnchor, gauge)) {
            fprintf(stderr, "gauge %.1f,%.1f vs %.1f,%.1f (%s)\n",
                    gaugeAnchor.frame.origin.x, gaugeAnchor.frame.size.width,
                    gauge.frame.origin.x, gauge.frame.size.width, ident.UTF8String);
            return NO;
        }
    }
    return YES;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSMutableDictionary *arguments = [[NSUserDefaults.standardUserDefaults volatileDomainForName:NSArgumentDomain] mutableCopy];
        arguments[@"starlinkCapGB"] = @100;
        arguments[@"starlinkResetDay"] = @13;
        arguments[@"telstraCapGB"] = @180;
        arguments[@"telstraResetDay"] = @7;
        [NSUserDefaults.standardUserDefaults setVolatileDomain:arguments forName:NSArgumentDomain];
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        QuotaPairGauge *probe = [[QuotaPairGauge alloc] initWithFrame:NSMakeRect(0,0,100,8)];
        probe.firstFraction = 0.06; probe.secondFraction = 0.8;
        if (!Red(MeterPixel(probe,3,1)) || !Green(MeterPixel(probe,40,1)) ||
            !Green(MeterPixel(probe,40,6))) return Fail(__LINE__);
        probe.firstFraction = 0.8; probe.secondFraction = 0.06;
        if (!Green(MeterPixel(probe,40,4)) || !Red(MeterPixel(probe,3,4))) return Fail(__LINE__);
        probe.firstFraction = 0;
        if (!Red(MeterPixel(probe,3,4))) return Fail(__LINE__);
        // A full reset and near-ties use lanes, with each endpoint independently visible.
        probe.firstFraction = probe.secondFraction = 1;
        if (!Green(MeterPixel(probe,90,1)) || !Green(MeterPixel(probe,90,6))) return Fail(__LINE__);
        if (!QuotaFractionsClose(.30,.33) || QuotaFractionsClose(.30,.34) || QuotaFractionsClose(-1,0)) return Fail(__LINE__);
        probe.firstFraction = .30; probe.secondFraction = .32;
        if (!Red(MeterPixel(probe,20,1)) || !Red(MeterPixel(probe,20,6))) return Fail(__LINE__);
        // Two healthy quotas: solid green to the shorter (50%), a lighter green to 71%.
        probe.firstFraction = .50; probe.secondFraction = .71;
        {
            NSColor *solid = MeterPixel(probe,30,4), *tint = MeterPixel(probe,62,4), *track = MeterPixel(probe,90,4);
            if (!Green(solid) || !Green(tint) || Green(track)) return Fail(__LINE__);
            // The offscreen bitmap has no backdrop, so "lighter" shows up as lower alpha
            // (on screen it composites to a paler green over the track and window).
            if (tint.alphaComponent > solid.alphaComponent - 0.3 &&
                fabs(tint.greenComponent - solid.greenComponent) < 0.08 && fabs(tint.redComponent - solid.redComponent) < 0.08)
                return Fail(__LINE__);   // the extension must be visibly lighter than the solid fill
        }
        // User example: full-height amber to 30%, green from there to 60%.
        probe.firstFraction = .30; probe.secondFraction = .60;
        if (!Green(MeterPixel(probe,45,1)) || !Green(MeterPixel(probe,45,6))) return Fail(__LINE__);
        NSColor *lowOpus = MeterPixel(probe,20,4);
        __block NSColor *amber;
        [probe.appearance performAsCurrentDrawingAppearance:^{
            amber = [NSColor.systemOrangeColor colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        }];
        if (fabs(lowOpus.redComponent-amber.redComponent)>0.03 ||
            fabs(lowOpus.greenComponent-amber.greenComponent)>0.03 ||
            fabs(lowOpus.blueComponent-amber.blueComponent)>0.03) return Fail(__LINE__);
        NSString *fixtureHome = [NSHomeDirectory() stringByAppendingPathComponent:[@".glancebar-offline-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        gOfflineFixtureHome = fixtureHome; atexit(CleanupOfflineFixture);
        NSString *fixtureMusic = [fixtureHome stringByAppendingPathComponent:@"Music"];
        [NSFileManager.defaultManager createDirectoryAtPath:fixtureMusic withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *stationFixture = [fixtureMusic stringByAppendingPathComponent:@"station.m4a"];
        [@"synthetic silent fixture" writeToFile:stationFixture atomically:YES encoding:NSUTF8StringEncoding error:nil];
        setenv("GLANCEBAR_HOME", fixtureHome.UTF8String, 1);
        Controller *c = [Controller new];
        NSDictionary *offline = OfflineFixture(stationFixture, @"station:triplej");
        NSDictionary *kindPack = KindHarnessTracks(fixtureMusic, YES);
        if (!kindPack) return Fail(__LINE__);
        [c setValue:[@{@"station:triplej": offline[@"request"]} mutableCopy] forKey:@"offlineRequests"];
        [c setValue:MergeOfflineManifest(offline[@"manifest"], kindPack[@"manifest"]) forKey:@"offlineManifest"];
        // Kind tiles from a fixture library: the harness never reads the real Music library.
        [c setValue:@YES forKey:@"mixFrozen"];
        [c setValue:@YES forKey:@"audioFrozen"];   // never read this Mac's live volume mid-check
        [c setValue:kindPack[@"library"] forKey:@"mixLibrary"];
        [c setValue:@YES forKey:@"stationLoaded"];
        [c setValue:@YES forKey:@"stationAvailable"];
        [c setValue:@[stationFixture] forKey:@"stationFiles"];
        [c setValue:@[
            @{@"title": @"Kiss from a Rose", @"artist": @"Tame Impala", @"reason": @"like Tame Impala", @"file": stationFixture},
            @{@"title": @"Danielle", @"artist": @"Fred again..", @"reason": @"like Fred again..", @"file": @""},
            @{@"title": @"A Girl Like You", @"artist": @"Tame Impala", @"reason": @"like Tame Impala", @"file": @""}
        ] forKey:@"stationPicks"];
        [c setValue:@"limit80" forKey:@"chargeMode"];
        [c setValue:@YES forKey:@"chargeModeLoaded"];
        NSPopover *p = [NSPopover new];
        p.contentViewController = [NSViewController new];
        [c setValue:p forKey:@"popover"];
        Volume *v = [Volume new]; v.name = @"Macintosh HD"; v.path = @"/";
        v.total = 1000000000000; v.available = 250000000000; v.isInternal = YES;
        NSMutableArray *volumes = [NSMutableArray arrayWithObject:v];
        for (int i=0; i<7; i++) {
            Volume *extra = [Volume new]; extra.name = [NSString stringWithFormat:@"External %d", i];
            extra.path = [@"/Volumes/" stringByAppendingString:extra.name];
            extra.total = v.total; extra.available = 500000000000;
            [volumes addObject:extra];
        }
        [c setValue:volumes forKey:@"vols"];
        [c setValue:@YES forKey:@"volumesUnavailable"];
        [c setValue:[NSDate dateWithTimeIntervalSinceNow:-3600] forKey:@"lastVolumeSuccess"];
        SystemState sys = {.cpuValid=YES, .memValid=YES, .swapValid=YES, .cpu=0.24,
            .memTotal=34359738368, .memUsed=17179869184, .memAvailable=17179869184, .kernPressure=1,
            .tempValid=YES, .cpuTempC=101.4, .thermalValid=YES, .thermalPressure=2,
            .clocks={.valid=YES, .pMHz=2321, .pMaxMHz=4464, .pBusy=0.9, .eMHz=2100, .eMaxMHz=3048, .eBusy=0.95}};
        [c setValue:[NSValue valueWithBytes:&sys objCType:@encode(SystemState)] forKey:@"sys"];
        [c setValue:@0.52 forKey:@"heatSpeed"];
        BatteryState b = {.valid=YES, .percent=61, .acConnected=YES, .isCharging=YES,
            .rawCurrent_mAh=2745, .rawMax_mAh=4500, .designCap_mAh=5000, .voltage_mV=12000, .amperage_mA=1000,
            .cycleCount=120, .systemPowerIn_mW=18800, .systemLoad_mW=6800, .adapterWatts=20};
        [c setValue:[NSValue valueWithBytes:&b objCType:@encode(BatteryState)] forKey:@"bat"];
        PrimeBatteryForecast(c, b, YES);
        [c setValue:@YES forKey:@"showWatts"]; [c setValue:@YES forKey:@"showHealth"];
        NSMutableArray *usage = [NSMutableArray array];
        for (NSString *name in @[@"Claude", @"Codex", @"Cursor"]) {
            AIUsage *u = [AIUsage new]; u.name = name; u.available = YES;
            u.limitStatusAvailable = YES; u.remainingFraction = [name isEqual:@"Codex"] ? 0.06 : 0.73;
            u.resetAt = [NSDate dateWithTimeIntervalSinceNow:3*86400];
            u.limitWindows = @[@{@"remainingFraction":@0.06, @"window":@"weekly", @"bucket":@"codex"},
                @{@"remainingFraction":@1, @"window":@"5-hour", @"bucket":@"codex_bengalfox"},
                @{@"remainingFraction":@1, @"window":@"weekly", @"bucket":@"codex_bengalfox"}];
            if ([name isEqual:@"Claude"]) u.limitWindows = @[
                @{@"remainingFraction":@0.57, @"window":@"5-hour", @"resetsAt":@(NSDate.date.timeIntervalSince1970 + 7200)},
                @{@"remainingFraction":@0.33, @"window":@"weekly", @"resetsAt":@(NSDate.date.timeIntervalSince1970 + 86400)},
                @{@"remainingFraction":@0.06, @"window":@"weekly Fable"}];
            if ([name isEqual:@"Codex"]) { u.limitStale = YES; u.limitUpdatedAt = [NSDate dateWithTimeIntervalSinceNow:-3600]; }
            [usage addObject:u];
        }
        [c setValue:usage forKey:@"aiUsage"];
        [c setValue:NSDate.date forKey:@"lastMachineRefresh"];
        [c setValue:NSDate.date forKey:@"lastAIRefresh"];
        [c setValue:@[@{@"uid": @"bose", @"name": @"Bose Flex SoundLink",
                        @"transport": @(GlanceAudioTransportBluetooth), @"outputChannels": @2,
                        @"dataSource": @""}] forKey:@"audioDevices"];
        [c setValue:@"bose" forKey:@"defaultOutputUID"];
        // This binary keeps NSUserDefaults under its own name. A failure inside the M2
        // block used to return before removing remoteMachines, so the next run grew an
        // extra fleet gauge (popover.remote.<host>.gauge).
        NSUserDefaults *fixtureDefaults = NSUserDefaults.standardUserDefaults;
        [fixtureDefaults removeObjectForKey:@"remoteMachines"];
        [fixtureDefaults removeObjectForKey:@"remoteOpen.m2"];
        [c rebuildContent];
        NSView *root = p.contentViewController.view;
        printf("Popover: %.0f × %.0f; gauges: %lu; scroll: %s\n",root.frame.size.width, root.frame.size.height,
               (unsigned long)CountGauges(root), FirstScrollView(root) ? "yes" : "no");
        if (FirstScrollView(root) || root.frame.size.height > 564 || CountGauges(root) != 6 ||   // + Heat, under pressure
            HasText(root,@"bengalfox") || !HasText(root,@"stale 1h")) return Fail(__LINE__);
        if (FindIdentifier(root,@"popover.ai.codex.gauge") ||
            ![((NSTextField *)FindIdentifier(root,@"popover.ai.codex.value")).stringValue isEqual:@"—"]) return Fail(__LINE__);
        if (argc>1) {
            NSString *path=[[[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension] stringByAppendingString:@"-codex-stale.png"];
            if (!RenderOffscreen(root,path,argc>2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)) return Fail(__LINE__);
        }
        // The remaining geometry checks exercise current, fully populated rows.
        AIUsage *currentCodex=usage[1];currentCodex.limitStale=NO;currentCodex.limitUpdatedAt=NSDate.date;
        [c rebuildContent];root=p.contentViewController.view;
        // Token indexing is internal machinery: it never reaches an instrument (2026-10-06).
        [c setValue:@YES forKey:@"_aiTotalsIncomplete"];
        [c setValue:@"Indexing 96% · totals incomplete" forKey:@"_aiCatchUpStatus"];
        [c rebuildContent];
        if (HasText(root, @"ndexing")) return Fail(__LINE__);
        [c setValue:@NO forKey:@"_aiTotalsIncomplete"];
        [c rebuildContent];
        if (HasText(root, @"STORAGE") || HasText(root, @"BATTERY") || HasText(root, @"SYSTEM") ||
            HasText(root, @"SOUND") || HasText(root, @"AI STATUS") ||
            FindIdentifier(root, @"popover.heading.storage") || FindIdentifier(root, @"popover.storage.details") ||
            HasText(root, @"drives")) return Fail(__LINE__);
        if (!InstrumentRowsFit(root) || !FitsChildren(root)) return Fail(__LINE__);
        NSView *storageGauge = FindIdentifier(root, @"popover.storage.gauge");
        NSView *batteryGauge = FindIdentifier(root, @"popover.battery.gauge");
        NSView *codexGauge = FindIdentifier(root, @"popover.ai.codex.gauge");
        NSView *cursorGauge = FindIdentifier(root, @"popover.ai.cursor.gauge");
        QuotaPairGauge *meter = FindClaudeMeter(root);
        if (!SameColumn(storageGauge, batteryGauge) || !SameColumn(storageGauge, meter) ||
            !SameColumn(storageGauge, codexGauge) || !SameColumn(storageGauge, cursorGauge)) return Fail(__LINE__);
        if (fabs(storageGauge.frame.size.width - batteryGauge.frame.size.width) > 0.5 ||
            fabs(storageGauge.frame.size.width - meter.frame.size.width) > 0.5 ||
            fabs(storageGauge.frame.origin.x - kGaugeX) > 0.5 ||
            fabs(storageGauge.frame.size.width - kGaugeW) > 0.5) return Fail(__LINE__);
        if (!SameColumn(FindIdentifier(root, @"popover.storage.value"), FindIdentifier(root, @"popover.battery.value")) ||
            !SameColumn(FindIdentifier(root, @"popover.storage.value"), FindIdentifier(root, @"popover.claude.value")) ||
            !SameColumn(FindIdentifier(root, @"popover.storage.value"), FindIdentifier(root, @"popover.ai.codex.value")) ||
            fabs(FindIdentifier(root, @"popover.storage.value").frame.origin.x - kValueX) > 0.5 ||
            fabs(FindIdentifier(root, @"popover.storage.datum").frame.origin.x - kDatumX) > 0.5)
            return Fail(__LINE__);
        // Machine rows stay symbol-only. AI rows add the provider name beside the logo,
        // and every symbol still shares the lead column.
        NSView *storageSymbol = FindIdentifier(root, @"popover.storage.symbol");
        NSButton *batterySymbol = (NSButton *)FindIdentifier(root, @"popover.battery.symbol");
        NSArray *symbols = @[
            storageSymbol,
            batterySymbol,
            FindIdentifier(root, @"popover.system.symbol"),
            FindIdentifier(root, @"popover.ai.claude.symbol"),
            FindIdentifier(root, @"popover.ai.codex.symbol"),
            FindIdentifier(root, @"popover.ai.cursor.symbol"),
        ];
        for (NSView *lead in symbols) {
            if (!lead || !SameColumn(storageSymbol, lead) || !SameSize(storageSymbol, lead)) return Fail(__LINE__);
        }
        if (![storageSymbol isKindOfClass:NSImageView.class]) return Fail(__LINE__);
        if (![batterySymbol isKindOfClass:NSButton.class] || batterySymbol.action == NULL) return Fail(__LINE__);
        // Quantity plus flow: a trend arrow above the charge bar from the level toward where it
        // is heading (stopping at the 80% limit), and the signed rate as the datum.
        NSTextField *batteryDatum = (NSTextField *)FindIdentifier(root, @"popover.battery.datum");
        TrendArrow *trend = (TrendArrow *)FindIdentifier(root, @"popover.battery.trend");
        NSView *chargeGauge = FindIdentifier(root, @"popover.battery.gauge");
        if (![batteryDatum.stringValue isEqual:@"+12 W"] || ![batteryDatum.textColor isEqual:NSColor.systemGreenColor] ||
            ![trend isKindOfClass:TrendArrow.class] || trend.hidden || trend.to <= trend.from || trend.to > 0.8001 ||
            fabs(NSMidY(trend.frame) - NSMidY(chargeGauge.frame)) > 0.5) return Fail(__LINE__);   // in line with the bar
        NSString *levelName = BatterySymbolName(b.percent, NO);
        CGFloat levelPt = FittedSymbolPointSize(levelName, kLeadSymbol, kLeadW);
        NSImageSymbolConfiguration *plainCfg = [NSImageSymbolConfiguration configurationWithPointSize:levelPt
                                                                                               weight:NSFontWeightRegular];
        NSImage *plainGlyph = [[NSImage imageWithSystemSymbolName:levelName accessibilityDescription:nil]
                               imageWithSymbolConfiguration:plainCfg];
        NSColor *ink = PowerFlowColor(b, NSColor.secondaryLabelColor);
        NSImage *plainTinted = [NSImage imageWithSize:plainGlyph.size flipped:NO drawingHandler:^BOOL(NSRect dst) {
            [plainGlyph drawInRect:dst];
            [ink set];
            NSRectFillUsingOperation(dst, NSCompositingOperationSourceAtop);
            return YES;
        }];
        // Charging bakes a non-template image. Same colour, no badge, must still differ.
        if (batterySymbol.image.template || !RenderedImagesDiffer(batterySymbol.image, plainTinted))
            return Fail(__LINE__);
        int etaMin = [c chargeForecastMinutes];
        NSString *etaPhrase = [NSString stringWithFormat:@"80%% ~%@", BatteryForecastClock([c batteryForecast].thresholdTime, nil)];
        NSView *batteryRow = FindIdentifier(root, @"popover.row.battery");
        if (etaMin < 0 || ![batteryRow.accessibilityHelp containsString:etaPhrase]) return Fail(__LINE__);
        NSPoint symbolMid = [batterySymbol convertPoint:NSMakePoint(NSMidX(batterySymbol.bounds),
                                                                     NSMidY(batterySymbol.bounds))
                                                  toView:batterySymbol.superview.superview];
        NSView *symbolHit = [batterySymbol.superview hitTest:symbolMid];
        if (symbolHit != batterySymbol) return Fail(__LINE__);
        Gauge *batteryMeter = (Gauge *)batteryGauge;
        if (![batteryMeter isKindOfClass:Gauge.class] || !ForecastFits((BatteryForecastView *)FindIdentifier(root, @"popover.battery.forecast")))
            return Fail(__LINE__);
        if (fabs(storageSymbol.frame.origin.x - kPad) > 0.5 ||
            fabs(storageSymbol.frame.size.width - kLeadW) > 0.5 ||
            fabs(storageSymbol.frame.size.height - kLeadSymbol) > 0.5) return Fail(__LINE__);
        NSTextField *claudeName = (NSTextField *)FindIdentifier(root, @"popover.ai.claude.name");
        NSTextField *codexName = (NSTextField *)FindIdentifier(root, @"popover.ai.codex.name");
        NSTextField *cursorName = (NSTextField *)FindIdentifier(root, @"popover.ai.cursor.name");
        if (![claudeName isKindOfClass:NSTextField.class] || ![claudeName.stringValue isEqual:@"Claude"] ||
            ![codexName.stringValue isEqual:@"Codex"] || ![cursorName.stringValue isEqual:@"Cursor"] ||
            !SameColumn(claudeName, codexName) || !SameColumn(claudeName, cursorName) ||
            fabs(claudeName.frame.origin.x - kAINameX) > 0.5)
            return Fail(__LINE__);
        // Every row names itself, in one column with the AI names.
        NSTextField *popStorageName = (NSTextField *)FindIdentifier(root, @"popover.storage.name");
        NSTextField *popBatteryName = (NSTextField *)FindIdentifier(root, @"popover.battery.name");
        NSTextField *popSystemName = (NSTextField *)FindIdentifier(root, @"popover.system.name");
        if (![popStorageName.stringValue isEqual:@"Storage"] || ![popBatteryName.stringValue isEqual:@"Battery"] ||
            ![popSystemName.stringValue isEqual:@"System"] || !SameColumn(popStorageName, claudeName) ||
            !SameColumn(popBatteryName, claudeName) || !SameColumn(popSystemName, claudeName))
            return Fail(__LINE__);
        // Under pressure a Heat row follows System: fast-core speed, then chip · cells.
        NSTextField *heatValue = (NSTextField *)FindIdentifier(root, @"popover.heat.value");
        NSTextField *heatDatum = (NSTextField *)FindIdentifier(root, @"popover.heat.datum");
        NSTextField *heatName = (NSTextField *)FindIdentifier(root, @"popover.heat.name");
        if (!FindIdentifier(root, @"popover.row.heat") || ![heatName.stringValue isEqual:@"Speed"] ||
            !((Gauge *)FindIdentifier(root, @"popover.heat.gauge")).lossColor ||
            ![heatValue.stringValue isEqual:@"52%"] || ![heatValue.textColor isEqual:NSColor.systemRedColor] ||
            ![HeatDatumText(heatDatum) isEqual:@"[cpu]101°"] || ![HeatDatumColor(heatDatum, 0) isEqual:NSColor.systemRedColor] ||
            !SameColumn(heatDatum, batteryDatum) || !SameColumn(heatName, popSystemName) ||
            FindIdentifier(root, @"popover.system.heat") || !HasTip(root, @"Fast cores at 52% of top speed"))
            return Fail(__LINE__);
        if (argc > 1) {
            NSString *path = [[[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension] stringByAppendingString:@"-heat.png"];
            if (!RenderOffscreen(root, path, argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)) return Fail(__LINE__);
        }
        {   // The Thermal tab: pressure lamps, both clusters against their top clocks, chip.
            NSView *thermal = [c thermalDetailsView].documentView;
            NSTextField *(^field)(NSString *) = ^NSTextField *(NSString *ident) {
                return (NSTextField *)FindIdentifier(thermal, [@"details.thermal." stringByAppendingString:ident]);
            };
            if (![field(@"pressure.value").stringValue isEqual:@"heavy"] || !FindIdentifier(thermal, @"details.thermal.pressure.lamps") ||
                ![field(@"fast.value").stringValue isEqual:@"2.3"] || ![field(@"fast.datum").stringValue isEqual:@"of 4.5 GHz"] ||
                ![field(@"efficient.value").stringValue isEqual:@"2.1"] || ![field(@"efficient.datum").stringValue isEqual:@"of 3.0 GHz"] ||
                ![field(@"chip.value").stringValue isEqual:@"101°"] || ![field(@"fast.value").textColor isEqual:NSColor.systemRedColor] ||
                !SameColumn(field(@"fast.value"), field(@"chip.value")) || FindIdentifier([c systemDetailsView].documentView, @"details.system.row.heat") ||
                !FitsChildren(thermal)) return Fail(__LINE__);
            const char *thermalOut = getenv("GLANCEBAR_RENDER_THERMAL");
            if (thermalOut && thermalOut[0] && !RenderOffscreen(thermal, [NSString stringWithUTF8String:thermalOut],
                                                               argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)) return Fail(__LINE__);
        }
        {   // Cells join the chip in the Heat datum; the Battery datum keeps its watts.
            BatteryState warm = b; warm.tempC = 31.3;
            [c setValue:[NSValue valueWithBytes:&warm objCType:@encode(BatteryState)] forKey:@"bat"];
            [c rebuildContent];
            NSView *warmRoot = p.contentViewController.view;
            NSTextField *pair = (NSTextField *)FindIdentifier(warmRoot, @"popover.heat.datum");
            NSTextField *watts = (NSTextField *)FindIdentifier(warmRoot, @"popover.battery.datum");
            if (![HeatDatumText(pair) isEqual:@"[cpu]101° [battery]31°"] || ![HeatDatumColor(pair, 1) isEqual:NSColor.secondaryLabelColor] ||
                ![watts.stringValue isEqual:@"+12 W"] || !FitsChildren(warmRoot) ||
                ![watts.textColor isEqual:NSColor.systemGreenColor]) return Fail(__LINE__);
        }
        {   // Hot cells with a cool chip still bring the row; the cells set its colour.
            SystemState cool = sys; cool.thermalPressure = 0; cool.cpuTempC = 61;
            [c setValue:[NSValue valueWithBytes:&cool objCType:@encode(SystemState)] forKey:@"sys"];
            BatteryState hot = b; hot.tempC = 41.6;
            [c setValue:[NSValue valueWithBytes:&hot objCType:@encode(BatteryState)] forKey:@"bat"];
            [c setValue:@1.0 forKey:@"heatSpeed"];
            [c rebuildContent];
            NSView *hotRoot = p.contentViewController.view;
            NSTextField *hotDatum = (NSTextField *)FindIdentifier(hotRoot, @"popover.heat.datum");
            NSTextField *hotValue = (NSTextField *)FindIdentifier(hotRoot, @"popover.heat.value");
            if (![HeatDatumText(hotDatum) isEqual:@"[cpu]61° [battery]42°"] || ![HeatDatumColor(hotDatum, 0) isEqual:NSColor.secondaryLabelColor] ||
                ![HeatDatumColor(hotDatum, 1) isEqual:NSColor.systemRedColor] || hotDatum.intrinsicContentSize.width > NSWidth(hotDatum.frame) ||
                ![hotValue.stringValue isEqual:@"100%"] || ![hotValue.textColor isEqual:NSColor.systemGreenColor] ||
                !HasTip(hotRoot, @"cells 42 °C") || !FitsChildren(hotRoot)) return Fail(__LINE__);
            if (argc > 1) {
                NSString *path = [[[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension] stringByAppendingString:@"-battery-hot.png"];
                if (!RenderOffscreen(hotRoot, path, argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)) return Fail(__LINE__);
            }
            [c setValue:[NSValue valueWithBytes:&sys objCType:@encode(SystemState)] forKey:@"sys"];
            [c setValue:@0.52 forKey:@"heatSpeed"];
        }
        {   // Both cool: no Heat row.
            SystemState cool = sys; cool.thermalPressure = 0; cool.cpuTempC = 55;
            BatteryState mild = b; mild.tempC = 30;
            [c setValue:[NSValue valueWithBytes:&cool objCType:@encode(SystemState)] forKey:@"sys"];
            [c setValue:[NSValue valueWithBytes:&mild objCType:@encode(BatteryState)] forKey:@"bat"];
            [c rebuildContent];
            if (FindIdentifier(p.contentViewController.view, @"popover.row.heat")) return Fail(__LINE__);
            // Speed row always: the same row stays up while cool, 100% green with the temperatures.
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"speedAlways"];
            [c setValue:@1.0 forKey:@"heatSpeed"];
            [c rebuildContent]; root = p.contentViewController.view;
            NSTextField *coolValue = (NSTextField *)FindIdentifier(root, @"popover.heat.value");
            NSTextField *coolDatum = (NSTextField *)FindIdentifier(root, @"popover.heat.datum");
            if (!FindIdentifier(root, @"popover.row.heat") || ![coolValue.stringValue isEqual:@"100%"] ||
                ![coolValue.textColor isEqual:NSColor.systemGreenColor] ||
                ![HeatDatumText(coolDatum) isEqual:@"[cpu]55° [battery]30°"] ||
                ((Gauge *)FindIdentifier(root, @"popover.heat.gauge")).lossColor ||
                !FindIdentifier([c overviewDetailsView].documentView, @"details.overview.row.heat") ||
                !FitsChildren(root) || !InstrumentRowsFit(root)) return Fail(__LINE__);
            if (argc > 1) {
                NSString *path = [[[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension] stringByAppendingString:@"-speed-always.png"];
                if (!RenderOffscreen(root, path, argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)) return Fail(__LINE__);
            }
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"speedAlways"];
            [c setValue:@0.52 forKey:@"heatSpeed"];
            [c rebuildContent];
            if (FindIdentifier(p.contentViewController.view, @"popover.row.heat")) return Fail(__LINE__);
            // The rest of the checks run cool, without the Heat row.
            [c setValue:[NSValue valueWithBytes:&b objCType:@encode(BatteryState)] forKey:@"bat"];
            [c rebuildContent];
            root = p.contentViewController.view;
        }
        if (!HasTip(root, @"Claude —") || !HasTip(root, @"Codex —") || !HasTip(root, @"Cursor —"))
            return Fail(__LINE__);
        NSTextField *claudeDatum = (NSTextField *)FindIdentifier(root, @"popover.ai.claude.datum");
        if (![claudeDatum.stringValue hasPrefix:@"resets "]) return Fail(__LINE__);
        [c setValue:@YES forKey:@"mixFrozen"];
        [c setValue:[NSMutableDictionary dictionary] forKey:@"offlineRequests"];
        [c rebuildContent];
        root = p.contentViewController.view;
        NSView *output = FindIdentifier(root, @"popover.sound");
        NSTextField *musicSubtitle = (NSTextField *)FindIdentifier(root, @"popover.music.subtitle");
        if (!SoundRow(root, @"Liked Music", musicSubtitle.stringValue, NO) ||
            ![musicSubtitle.stringValue hasSuffix:@"on this Mac"] ||
            FindIdentifier(root, @"popover.music.open") ||
            FindIdentifier(root, @"popover.music.shuffle") ||
            ![output.accessibilityLabel isEqual:@"Player output, System, Bose Flex SoundLink"] ||
            ![output.accessibilityHelp containsString:@"Glancebar's player"]) return Fail(__LINE__);
        {   // Where it will play and how loud: name beside the symbol, level coloured when loud or muted.
            NSButton *outputButton = (NSButton *)output;
            NSSlider *volume = (NSSlider *)FindIdentifier(root, @"popover.sound.volume");
            NSTextField *level = (NSTextField *)FindIdentifier(root, @"popover.sound.level");
            [c setValue:@0.55 forKey:@"outputVolume"]; [c setValue:@NO forKey:@"outputMuted"];
            [c rebuildContent]; root = p.contentViewController.view;
            volume = (NSSlider *)FindIdentifier(root, @"popover.sound.volume");
            level = (NSTextField *)FindIdentifier(root, @"popover.sound.level");
            outputButton = (NSButton *)FindIdentifier(root, @"popover.sound");
            if (![outputButton.title containsString:@"Bose Flex SoundLink"] || fabs(volume.doubleValue - 0.55) > 0.001 ||
                !volume.enabled || ![level.stringValue isEqual:@"55%"] || ![level.textColor isEqual:NSColor.secondaryLabelColor] ||
                ((NSButtonCell *)outputButton.cell).lineBreakMode != NSLineBreakByTruncatingTail ||
                FindIdentifier(root, @"popover.sound.picker.chevron") || !FitsChildren(root)) return Fail(__LINE__);
            [c setValue:@0.85 forKey:@"outputVolume"]; [c rebuildContent]; root = p.contentViewController.view;
            level = (NSTextField *)FindIdentifier(root, @"popover.sound.level");
            if (![level.stringValue isEqual:@"85%"] || ![level.textColor isEqual:NSColor.systemOrangeColor]) return Fail(__LINE__);
            [c setValue:@YES forKey:@"outputMuted"]; [c rebuildContent]; root = p.contentViewController.view;
            level = (NSTextField *)FindIdentifier(root, @"popover.sound.level");
            outputButton = (NSButton *)FindIdentifier(root, @"popover.sound");
            NSImageView *volSymbol = (NSImageView *)FindIdentifier(root, @"popover.sound.volume.symbol");
            if (![level.stringValue isEqual:@"mute"] || ![level.textColor isEqual:NSColor.systemRedColor] ||
                ![volSymbol isKindOfClass:NSImageView.class] ||
                ![volSymbol.contentTintColor isEqual:NSColor.systemRedColor]) return Fail(__LINE__);
            [c setValue:@0.55 forKey:@"outputVolume"]; [c setValue:@NO forKey:@"outputMuted"];
            [c rebuildContent]; root = p.contentViewController.view;
        }
        if (FindIdentifier(root, @"popover.route.com.apple.Music")) return Fail(__LINE__);
        {   // Playing elsewhere while idle.
            NSDictionary *ext = ParseExternalPlayback(@{@"Name": @"Jubel", @"Artist": @"Klingande",
                                                        @"Player State": @"Playing"}, @"music");
            [c setValue:ext forKey:@"_externalPlayback"];
            [c rebuildContent]; root = p.contentViewController.view;
            if (![[(NSTextField *)FindIdentifier(root, @"popover.music.title") stringValue] isEqual:@"Jubel"] ||
                !FindIdentifier(root, @"popover.music.external") ||
                FindIdentifier(root, @"popover.music.favorite")) return Fail(__LINE__);
            [c setValue:nil forKey:@"_externalPlayback"];
            [c rebuildContent]; root = p.contentViewController.view;
        }
        [c setValue:[@{@"station:triplej": offline[@"request"]} mutableCopy] forKey:@"offlineRequests"];
        [c setValue:MergeOfflineManifest(offline[@"manifest"], kindPack[@"manifest"]) forKey:@"offlineManifest"];
        [c setValue:kindPack[@"library"] forKey:@"mixLibrary"];
        [c ensureOfflinePlaylists];
        [c rebuildContent]; root = p.contentViewController.view;
        {   // Dance, Alt, Rap, Chill kind tiles and the New music station; five 54pt covers in one row.
            NSView *mix = FindIdentifier(root, @"popover.mix");
            NSView *line = FindIdentifier(root, @"popover.sound.line");
            NSDictionary *counts = @{@"dance": @2, @"alt": @2, @"rap": @2, @"chill": @1};
            if (!mix || !line || NSMinY(mix.frame) < NSMaxY(line.frame) - 0.5 ||
                !KindMixRowOK(root, 5, 54, counts, nil) || !FitsChildren(root))
                return Fail(__LINE__);
            NSView *badge = FindIdentifier(root, @"popover.mix.station.badge");
            NSButton *station = (NSButton *)FindIdentifier(root, @"popover.mix.station");
            if (!badge || ![badge.accessibilityLabel isEqual:@"3 new picks"] || station.alphaValue < 0.95)
                return Fail(__LINE__);
            [c setValue:@"kind:dance" forKey:@"mixPlayingKey"];
            [c setValue:@YES forKey:@"localMode"];
            [c rebuildContent]; root = p.contentViewController.view;
            if (!KindMixRowOK(root, 5, 54, counts, @"dance")) return Fail(__LINE__);
            [c setValue:@NO forKey:@"localMode"]; [c setValue:nil forKey:@"mixPlayingKey"];
            [c rebuildContent]; root = p.contentViewController.view;
            // Kind tiles stay visible whenever music is enabled; network state no longer hides them.
            [c setValue:@YES forKey:@"musicProbesEnabled"];
            [c setValue:@YES forKey:@"networkKnown"];
            [c setValue:@NO forKey:@"networkOnline"];
            [c rebuildContent]; root = p.contentViewController.view;
            if (!KindTileButton(root, @"dance")) return Fail(__LINE__);
            [c setValue:@NO forKey:@"musicProbesEnabled"];
            [c setValue:@NO forKey:@"networkKnown"];
            [c setValue:@YES forKey:@"networkOnline"];
            [c rebuildContent]; root = p.contentViewController.view;
            {   // Missing station.json dims the tile and hides the count. It must not remove the row.
                [c setValue:@NO forKey:@"stationAvailable"];
                [c setValue:@[] forKey:@"stationPicks"];
                [c rebuildContent]; root = p.contentViewController.view;
                NSButton *dimmed = (NSButton *)FindIdentifier(root, @"popover.mix.station");
                GBStationTile *cardTile = (GBStationTile *)dimmed;
                if (!dimmed || dimmed.alphaValue > 0.5 || FindIdentifier(root, @"popover.mix.station.badge") ||
                    !KindTileButton(root, @"dance") || MixRowHasLegacySeedTiles(root) ||
                    ![cardTile isKindOfClass:GBStationTile.class]) return Fail(__LINE__);
                [c setValue:@YES forKey:@"stationAvailable"];
                [c setValue:@[
                    @{@"title": @"Kiss from a Rose", @"artist": @"Tame Impala", @"reason": @"like Tame Impala", @"file": stationFixture},
                    @{@"title": @"Danielle", @"artist": @"Fred again..", @"reason": @"like Fred again..", @"file": @""},
                    @{@"title": @"A Girl Like You", @"artist": @"Tame Impala", @"reason": @"like Tame Impala", @"file": @""}
                ] forKey:@"stationPicks"];
                [c rebuildContent]; root = p.contentViewController.view;
                GBStationTile *stationTile = (GBStationTile *)FindIdentifier(root, @"popover.mix.station");
                NSView *card = [stationTile largeCard];
                NSTextField *reason = (NSTextField *)FindIdentifier(card, @"popover.mix.station.pick.reason.0");
                NSTextField *pickTitle = (NSTextField *)FindIdentifier(card, @"popover.mix.station.pick.title.0");
                GBSeedHover *hover = (GBSeedHover *)FindIdentifier(root, @"popover.mix.hover.station");
                if (![stationTile isKindOfClass:GBStationTile.class] || ![reason.stringValue isEqual:@"like Tame Impala"] ||
                    ![pickTitle.stringValue isEqual:@"Kiss from a Rose"] || hover.tile != stationTile ||
                    [hover hitTest:NSMakePoint(NSMidX(hover.frame), NSMidY(hover.frame))] ||
                    !FindIdentifier(root, @"popover.mix.station.badge")) return Fail(__LINE__);
            }
            const char *tilesPNG = getenv("GLANCEBAR_TILES_PNG");
            if (tilesPNG && tilesPNG[0]) {
                NSString *dir = [NSString stringWithUTF8String:tilesPNG];
                if (!RenderOffscreen(root, [dir stringByAppendingPathComponent:@"tiles-light.png"], NSAppearanceNameAqua) ||
                    !RenderOffscreen(root, [dir stringByAppendingPathComponent:@"tiles-dark.png"], NSAppearanceNameDarkAqua))
                    return Fail(__LINE__);
                [c rebuildContent]; root = p.contentViewController.view;
            }
        }
        {   // A local external disk is its own instrument. Disk images and network mounts stay in Details.
            Volume *docs = [Volume new];
            docs.name = @"Documents"; docs.path = @"/Volumes/Documents";
            docs.total = 300000000000LL; docs.available = 61500000000LL; docs.physicalAvailable = docs.available;
            docs.isLocal = YES;
            Volume *research = [Volume new];
            research.name = @"Research"; research.path = @"/Volumes/Research";
            research.total = 700000000000LL; research.available = 170000000000LL; research.physicalAvailable = research.available;
            research.isLocal = YES;
            Volume *image = [Volume new];
            image.name = @"Installer"; image.path = @"/Volumes/Installer";
            image.total = docs.total; image.available = docs.available; image.physicalAvailable = image.available;
            image.isLocal = YES; image.isDiskImage = YES;
            Volume *share = [Volume new];
            share.name = @"Share"; share.path = @"/Volumes/Share";
            share.total = docs.total; share.available = docs.available; share.physicalAvailable = share.available;
            NSMutableArray *withExternal = [volumes mutableCopy];
            [withExternal addObject:docs]; [withExternal addObject:research];
            [withExternal addObject:image]; [withExternal addObject:share];
            [c setValue:withExternal forKey:@"vols"];
            [c rebuildContent]; root = p.contentViewController.view;
            NSTextField *extName = (NSTextField *)FindIdentifier(root, @"popover.storage.1.name");
            NSTextField *extValue = (NSTextField *)FindIdentifier(root, @"popover.storage.1.value");
            NSTextField *extDatum = (NSTextField *)FindIdentifier(root, @"popover.storage.1.datum");
            NSTextField *researchName = (NSTextField *)FindIdentifier(root, @"popover.storage.2.name");
            NSTextField *researchValue = (NSTextField *)FindIdentifier(root, @"popover.storage.2.value");
            NSTextField *researchDatum = (NSTextField *)FindIdentifier(root, @"popover.storage.2.datum");
            if (![extName.stringValue isEqual:@"Documents"] || ![extValue.stringValue isEqual:@"80%"] ||
                ![extDatum.stringValue isEqual:@"61.5 GB free"] ||
                ![researchName.stringValue isEqual:@"Research"] || ![researchValue.stringValue isEqual:@"76%"] ||
                ![researchDatum.stringValue isEqual:@"170 GB free"] ||
                FindIdentifier(root, @"popover.storage.3.name") ||
                !SameColumn(extName, FindIdentifier(root, @"popover.storage.name")) ||
                !SameColumn(researchName, extName) ||
                !SameColumn(FindIdentifier(root, @"popover.storage.1.gauge"), FindIdentifier(root, @"popover.storage.gauge")) ||
                !SameColumn(extValue, FindIdentifier(root, @"popover.storage.value")) ||
                !SameColumn(extDatum, FindIdentifier(root, @"popover.storage.datum")) ||
                !InstrumentRowsFit(root) || !FitsChildren(root)) return Fail(__LINE__);
            NSScrollView *externalOverview = [c overviewDetailsView];
            NSTextField *overviewName = (NSTextField *)FindIdentifier(externalOverview.documentView, @"details.overview.storage.1.name");
            NSTextField *overviewValue = (NSTextField *)FindIdentifier(externalOverview.documentView, @"details.overview.storage.1.value");
            NSTextField *overviewResearch = (NSTextField *)FindIdentifier(externalOverview.documentView, @"details.overview.storage.2.name");
            if (![overviewName.stringValue isEqual:@"Documents"] || ![overviewValue.stringValue isEqual:@"80%"] ||
                ![overviewResearch.stringValue isEqual:@"Research"] ||
                FindIdentifier(externalOverview.documentView, @"details.overview.storage.3.name") ||
                !SameColumn(overviewName, FindIdentifier(externalOverview.documentView, @"details.overview.storage.name")) ||
                overviewName.toolTip.length)
                return Fail(__LINE__);
            if (argc > 1) {
                NSString *base = [[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension];
                if (!RenderOffscreen(root, [base stringByAppendingString:@"-external.png"], NSAppearanceNameAqua)) return Fail(__LINE__);
                if (!RenderOffscreen(root, [base stringByAppendingString:@"-external-dark.png"], NSAppearanceNameDarkAqua)) return Fail(__LINE__);
            }
            {   // Two APFS volumes in one container are one disk. A disk image on another disk is only in that disk's tooltip.
                Volume *otv = [Volume new];
                otv.name = @"OTV Mirror"; otv.path = @"/Volumes/OTV Mirror";
                otv.total = 2000000000000LL; otv.available = 1800000000000LL; otv.physicalAvailable = otv.available;
                otv.isLocal = YES; otv.container = @"disk5"; otv.containerBytes = otv.total;
                otv.hasVolumeUsed = YES; otv.volumeUsed = 200000000000LL;
                Volume *vault = [Volume new];
                vault.name = @"Vault-T"; vault.path = @"/Volumes/Vault-T";
                vault.total = otv.total; vault.available = otv.available; vault.physicalAvailable = vault.available;
                vault.isLocal = YES; vault.container = @"disk5"; vault.containerBytes = otv.total;
                vault.hasVolumeUsed = YES; vault.volumeUsed = 300000000000LL;
                Volume *stash = [Volume new];
                stash.name = @"Stash"; stash.path = @"/Volumes/Stash";
                stash.total = 4000000000000LL; stash.available = 1000000000000LL; stash.physicalAvailable = stash.available;
                stash.isLocal = YES; stash.container = @"disk4";
                Volume *image = [Volume new];
                image.name = @"Archive_Encrypted2"; image.path = @"/Volumes/Archive_Encrypted2";
                image.total = 2000000000000LL; image.available = 500000000000LL; image.physicalAvailable = image.available;
                image.isLocal = YES; image.isDiskImage = YES; image.container = @"disk9";
                image.backingPath = @"/Volumes/Stash/Archive_Encrypted2.sparsebundle";
                image.hasVolumeUsed = YES; image.volumeUsed = 1500000000000LL;
                NSMutableArray *grouped = [volumes mutableCopy];
                [grouped addObject:otv]; [grouped addObject:vault];
                [grouped addObject:stash]; [grouped addObject:image];
                [c setValue:grouped forKey:@"vols"];
                [c rebuildContent]; root = p.contentViewController.view;
                NSTextField *groupName = (NSTextField *)FindIdentifier(root, @"popover.storage.1.name");
                NSTextField *groupValue = (NSTextField *)FindIdentifier(root, @"popover.storage.1.value");
                NSTextField *groupDatum = (NSTextField *)FindIdentifier(root, @"popover.storage.1.datum");
                NSView *groupRow = FindIdentifier(root, @"popover.row.storage.1");
                NSTextField *stashName = (NSTextField *)FindIdentifier(root, @"popover.storage.2.name");
                NSView *stashRow = FindIdentifier(root, @"popover.row.storage.2");
                if (![groupName.stringValue isEqual:@"OTV Mirror +1"] ||
                    ![groupName.accessibilityLabel isEqual:@"OTV Mirror · Vault-T"] ||
                    ![groupValue.stringValue isEqual:@"25%"] || ![groupDatum.stringValue isEqual:@"1.8 TB free"] ||
                    !HasTip(groupRow, @"OTV Mirror · Vault-T") || !HasTip(groupRow, @"Vault-T") ||
                    ![stashName.stringValue isEqual:@"Stash"] || !HasTip(stashRow, @"Archive_Encrypted2") ||
                    FindIdentifier(root, @"popover.storage.3.name") ||
                    !SameColumn(FindIdentifier(root, @"popover.storage.1.gauge"), FindIdentifier(root, @"popover.storage.gauge")) ||
                    !SameColumn(FindIdentifier(root, @"popover.storage.2.gauge"), FindIdentifier(root, @"popover.storage.gauge")) ||
                    !FitsChildren(root) || !InstrumentRowsFit(root)) return Fail(__LINE__);
                NSScrollView *groupedOverview = [c overviewDetailsView];
                NSTextField *groupedOverviewName = (NSTextField *)FindIdentifier(groupedOverview.documentView, @"details.overview.storage.1.name");
                if (![groupedOverviewName.stringValue isEqual:@"OTV Mirror +1"] ||
                    ![groupedOverviewName.accessibilityLabel isEqual:@"OTV Mirror · Vault-T"] ||
                    FindIdentifier(groupedOverview.documentView, @"details.overview.storage.3.name") ||
                    groupedOverviewName.toolTip.length) return Fail(__LINE__);
                if (argc > 1) {
                    NSString *base = [[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension];
                    if (!RenderOffscreen(root, [base stringByAppendingString:@"-containers.png"], NSAppearanceNameAqua)) return Fail(__LINE__);
                    if (!RenderOffscreen(root, [base stringByAppendingString:@"-containers-dark.png"], NSAppearanceNameDarkAqua)) return Fail(__LINE__);
                }
            }
            [c setValue:volumes forKey:@"vols"];
            [c rebuildContent]; root = p.contentViewController.view;
        }
        {   // Other Macs: one readiness row each (name, chevron, bar, score, what limits it); a click opens its four rows.
            NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
            [ud setObject:@[@{@"name": @"M2", @"host": @"m2"}] forKey:@"remoteMachines"];
            [ud setBool:NO forKey:@"remoteOpen.m2"];
            [c setValue:@(CFAbsoluteTimeGetCurrent()) forKey:@"remotePolledAt"];   // no real ssh from the harness
            NSDictionary *sample = @{@"cpu": @91, @"thermal": @"heavy", @"pMHz": @1188, @"pTopMHz": @3504, @"pBusy": @0.8, @"memPressure": @"Low",
                                     @"diskFreeGB": @218, @"diskTotalGB": @494, @"ac": @YES, @"batt": @76, @"battW": @3.1, @"chipC": @76, @"cellsC": @37,
                                     @"volumes": @[@{@"name": @"Archive", @"path": @"/Volumes/Archive",
                                                     @"totalBytes": @2000000000000LL, @"freeBytes": @500000000000LL,
                                                     @"internal": @NO, @"local": @YES, @"diskImage": @NO, @"boot": @NO}]};
            [c setValue:[@{@"m2": @{@"sample": sample, @"mode": @"full", @"free": @2, @"slots": @3, @"at": @(CFAbsoluteTimeGetCurrent())}} mutableCopy] forKey:@"remote"];
            [c rebuildContent]; root = p.contentViewController.view;
            NSMutableDictionary *badSample = [sample mutableCopy];
            badSample[@"cpu"] = NSNull.null;
            badSample[@"chipC"] = @"hot";
            [c setValue:[@{@"m2": @{@"sample": badSample, @"mode": @"full", @"free": @2, @"slots": @3, @"at": @(CFAbsoluteTimeGetCurrent())}} mutableCopy] forKey:@"remote"];
            [c rebuildContent]; root = p.contentViewController.view;
            if (!FindIdentifier(root, @"popover.row.remote.m2") || !FindIdentifier(root, @"popover.remote.m2.datum") || !FitsChildren(root))
                return Fail(__LINE__);
            [c setValue:[@{@"m2": @{@"sample": sample, @"mode": @"full", @"free": @2, @"slots": @3, @"at": @(CFAbsoluteTimeGetCurrent())}} mutableCopy] forKey:@"remote"];
            [c rebuildContent]; root = p.contentViewController.view;
            NSTextField *rv = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.value");
            NSTextField *rd = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.datum");
            NSTextField *rn = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.name");
            if (!FindIdentifier(root, @"popover.row.remote.m2") || ![rn.stringValue isEqual:@"M2"] || !FindIdentifier(root, @"popover.remote.m2.chevron") ||
                ![rv.stringValue isEqual:@"9%"] || ![rd.stringValue hasSuffix:@"CPU busy"] || ([rd.stringValue containsString:@"°"] ? ![[rd.attributedStringValue attribute:NSForegroundColorAttributeName atIndex:rd.stringValue.length - 1 effectiveRange:NULL] isEqual:NSColor.systemRedColor] : ![rd.textColor isEqual:NSColor.systemRedColor]) ||
                FindIdentifier(root, @"popover.remote.m2.storage") || FindIdentifier(root, @"popover.remote.m2.volume.0") ||
                !SameColumn(rn, FindIdentifier(root, @"popover.system.name")) ||
                !FitsChildren(root)) return Fail(__LINE__);
            [ud setBool:YES forKey:@"remoteOpen.m2"];
            [c rebuildContent]; root = p.contentViewController.view;
            NSTextField *sv = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.storage.value");
            NSTextField *sd = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.storage.datum");
            NSTextField *pv = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.speed.value");
            NSTextField *pd = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.speed.datum");
            // The other Mac's Speed datum carries the same chip and battery glyphs as this Mac's.
            if (![HeatDatumText(pd) isEqual:@"[cpu]76° [battery]37°"] || ![HeatDatumColor(pd, 0) isEqual:NSColor.systemRedColor] ||
                ![HeatDatumColor(pd, 1) isEqual:NSColor.secondaryLabelColor]) return Fail(__LINE__);
            NSTextField *ev = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.volume.0.value");
            NSTextField *en = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.volume.0.name");
            NSTextField *ed = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.volume.0.datum");
            if (![sv.stringValue isEqual:@"56%"] || ![sd.stringValue isEqual:@"218 GB free"] || ![pv.stringValue isEqual:@"34%"] ||
                ![en.stringValue isEqual:@"Archive"] || ![ev.stringValue isEqual:@"75%"] || ![ed.stringValue isEqual:@"500 GB free"] ||
                !SameColumn(en, FindIdentifier(root, @"popover.remote.m2.storage.name")) ||
                !FindIdentifier(root, @"popover.remote.m2.battery") || !FindIdentifier(root, @"popover.remote.m2.system") ||
                !FitsChildren(root) || !InstrumentRowsFit(root)) return Fail(__LINE__);
            if (argc > 1) {
                NSString *path = [[[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension] stringByAppendingString:@"-remote.png"];
                if (!RenderOffscreen(root, path, argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)) return Fail(__LINE__);
            }
            {   // The worker's two APFS volumes share disk5, so the drawer has one external row.
                NSDictionary *pair = @{@"cpu": @91, @"thermal": @"heavy", @"pMHz": @1188, @"pTopMHz": @3504, @"pBusy": @0.8,
                                       @"memPressure": @"Low", @"diskFreeGB": @218, @"diskTotalGB": @494, @"ac": @YES,
                                       @"batt": @76, @"battW": @3.1, @"chipC": @76, @"cellsC": @37,
                                       @"volumes": @[
                                           @{@"name": @"OTV Mirror", @"path": @"/Volumes/OTV Mirror", @"container": @"disk5",
                                             @"containerBytes": @2000000000000LL, @"containerFreeBytes": @1800000000000LL,
                                             @"totalBytes": @2000000000000LL, @"freeBytes": @1800000000000LL,
                                             @"usedBytes": @200000000000LL, @"internal": @NO, @"local": @YES,
                                             @"diskImage": @NO, @"boot": @NO},
                                           @{@"name": @"Vault-T", @"path": @"/Volumes/Vault-T", @"container": @"disk5",
                                             @"containerBytes": @2000000000000LL, @"containerFreeBytes": @1800000000000LL,
                                             @"totalBytes": @2000000000000LL, @"freeBytes": @1800000000000LL,
                                             @"usedBytes": @300000000000LL, @"internal": @NO, @"local": @YES,
                                             @"diskImage": @NO, @"boot": @NO}]};
                [c setValue:[@{@"m2": @{@"sample": pair, @"mode": @"full", @"free": @2, @"slots": @3, @"at": @(CFAbsoluteTimeGetCurrent())}} mutableCopy] forKey:@"remote"];
                [c rebuildContent]; root = p.contentViewController.view;
                NSTextField *pairName = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.volume.0.name");
                NSTextField *pairValue = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.volume.0.value");
                NSTextField *pairDatum = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.volume.0.datum");
                NSView *pairRow = FindIdentifier(root, @"popover.remote.m2.volume.0");
                if (![pairName.stringValue isEqual:@"OTV Mirror +1"] ||
                    ![pairName.accessibilityLabel isEqual:@"OTV Mirror · Vault-T"] ||
                    ![pairValue.stringValue isEqual:@"25%"] || ![pairDatum.stringValue isEqual:@"1.8 TB free"] ||
                    !HasTip(pairRow, @"OTV Mirror · Vault-T") || FindIdentifier(root, @"popover.remote.m2.volume.1") ||
                    !SameColumn(pairName, FindIdentifier(root, @"popover.remote.m2.storage.name")) ||
                    !SameColumn(FindIdentifier(root, @"popover.remote.m2.volume.0.gauge"), FindIdentifier(root, @"popover.remote.m2.storage.gauge")) ||
                    !FitsChildren(root) || !InstrumentRowsFit(root)) return Fail(__LINE__);
                if (argc > 1) {
                    NSString *base = [[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension];
                    if (!RenderOffscreen(root, [base stringByAppendingString:@"-containers-remote.png"], NSAppearanceNameAqua)) return Fail(__LINE__);
                    if (!RenderOffscreen(root, [base stringByAppendingString:@"-containers-remote-dark.png"], NSAppearanceNameDarkAqua)) return Fail(__LINE__);
                }
            }
            [c setValue:[@{@"m2": @{@"sample": sample, @"mode": @"full", @"free": @2, @"slots": @3, @"at": @(CFAbsoluteTimeGetCurrent() - 600)}} mutableCopy] forKey:@"remote"];
            [c rebuildContent]; root = p.contentViewController.view;
            rd = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.datum");
            if (![rd.stringValue isEqual:@"away 10m"] || FindIdentifier(root, @"popover.remote.m2.storage") ||
                FindIdentifier(root, @"popover.remote.m2.volume.0")) return Fail(__LINE__);
            {   // A worker behind this Mac keeps the same row: temperature, then one orange word.
                NSString *status = @"{\"state\":\"ok\",\"installed\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\","
                    "\"origin\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"behind\":3,"
                    "\"detail\":\"3 commits behind origin/main\"}";
                [c setValue:[@{@"m2": @{@"sample": sample, @"mode": @"full", @"free": @2, @"slots": @3,
                                        @"at": @(CFAbsoluteTimeGetCurrent()), @"glancebar": status,
                                        @"localSHA": @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}} mutableCopy] forKey:@"remote"];
                [ud setBool:NO forKey:@"remoteOpen.m2"];
                [c rebuildContent]; root = p.contentViewController.view;
                rd = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.datum");
                NSView *remoteRow = FindIdentifier(root, @"popover.row.remote.m2");
                NSRange word = [rd.stringValue rangeOfString:@"3 behind"];
                NSColor *wordColor = word.location == NSNotFound ? nil : [rd.attributedStringValue attribute:NSForegroundColorAttributeName atIndex:word.location effectiveRange:NULL];
                if (word.location == NSNotFound || ![wordColor isEqual:NSColor.systemOrangeColor] ||
                    ![rd.stringValue hasSuffix:@"CPU busy"] || FindIdentifier(root, @"popover.remote.m2.storage") ||
                    !HasTip(remoteRow, @"3 commits behind origin/main") || !FitsChildren(root) || !InstrumentRowsFit(root))
                    return Fail(__LINE__);
                status = @"{\"state\":\"no-release\",\"installed\":\"aaa\",\"origin\":\"bbb\",\"behind\":3,"
                    "\"detail\":\"matching signed release unavailable\"}";
                [c setValue:[@{@"m2": @{@"sample": sample, @"mode": @"full", @"free": @2, @"slots": @3,
                                        @"at": @(CFAbsoluteTimeGetCurrent()), @"glancebar": status,
                                        @"localSHA": @"bbb"}} mutableCopy] forKey:@"remote"];
                [c rebuildContent]; root = p.contentViewController.view;
                rd = (NSTextField *)FindIdentifier(root, @"popover.remote.m2.datum");
                remoteRow = FindIdentifier(root, @"popover.row.remote.m2");
                word = [rd.stringValue rangeOfString:@"no release"];
                wordColor = word.location == NSNotFound ? nil : [rd.attributedStringValue attribute:NSForegroundColorAttributeName atIndex:word.location effectiveRange:NULL];
                if (word.location == NSNotFound || ![wordColor isEqual:NSColor.systemOrangeColor] ||
                    FindIdentifier(root, @"popover.remote.m2.storage") ||
                    !HasTip(remoteRow, @"matching signed release unavailable") || !InstrumentRowsFit(root))
                    return Fail(__LINE__);
            }
            [ud removeObjectForKey:@"remoteMachines"]; [ud removeObjectForKey:@"remoteOpen.m2"];
            [c rebuildContent]; root = p.contentViewController.view;
        }
        // The footer carries exactly two controls plus the ⋯ menu, side by side, none clipped.
        NSView *keep = FindIdentifier(p.contentViewController.view, @"popover.keepAwake");
        NSView *low = FindIdentifier(p.contentViewController.view, @"popover.lowPower");
        NSView *more = FindIdentifier(p.contentViewController.view, @"popover.more");
        // The charge limit is a visible footer toggle, not a hidden click on the battery glyph.
        NSButton *chargeToggle = (NSButton *)FindIdentifier(p.contentViewController.view, @"popover.chargeLimit");
        if (![chargeToggle isKindOfClass:NSButton.class] || !chargeToggle.image ||
            ![chargeToggle.title isEqual:@"Limit 80%"] ||
            NSMaxX(chargeToggle.frame) + 4 > more.frame.origin.x) return Fail(__LINE__);
        NSButton *keepButton = (NSButton *)keep, *lowButton = (NSButton *)low, *moreButton = (NSButton *)more;
        if (![keepButton isKindOfClass:NSButton.class] || ![lowButton isKindOfClass:NSButton.class] ||
            ![moreButton isKindOfClass:NSButton.class]) return Fail(__LINE__);
        if (![keepButton.title isEqual:@"Keep Awake"] || ![lowButton.title isEqual:@"Low Power"] ||
            moreButton.title.length || !keepButton.image || !lowButton.image || !moreButton.image)
            return Fail(__LINE__);
        if (fabs(keepButton.frame.origin.x - kPad) > 0.5 ||
            fabs(NSMinX(lowButton.frame) - NSMaxX(keepButton.frame) - kToggleGap) > 0.5 ||
            fabs(NSMaxX(moreButton.frame) - (kW - kPad)) > 0.5 ||
            fabs(keepButton.frame.size.width - kKeepW) > 0.5 ||
            fabs(lowButton.frame.size.width - kLowW) > 0.5 ||
            fabs(keepButton.frame.size.height - kToggleH) > 0.5) return Fail(__LINE__);
        if (!keep || !low || !more || NSMaxX(keep.frame) > NSMinX(low.frame) || NSMaxX(low.frame) > NSMinX(more.frame) ||
            !FitsChildren(keep.superview)) return Fail(__LINE__);
        // One figure: the account weekly across all models (33%). No Fable figure, and the
        // 5-hour window never caps it. The weekly reset is on the tooltip, not a caption.
        if (!meter || meter.firstFraction >= 0 || fabs(meter.secondFraction-0.33)>0.001 || !HasText(root,@"33%") ||
            HasText(root,@"Fable") || HasText(root, @"5-hour") || HasText(root, @" left")) return Fail(__LINE__);
        if (!HasTip(root, @"week resets tomorrow")) return Fail(__LINE__);
        NSView *wordy = WordyTip(root);
        if (wordy) { fprintf(stderr, "unexpected hover tooltip on %s: %s\n", wordy.accessibilityIdentifier.UTF8String, wordy.toolTip.UTF8String); return Fail(__LINE__); }
        // The longest caption the row can produce must still fit: near-equal quotas (arrows),
        // a weekly reset named by weekday and date, and a cache-age note.
        AIUsage *longest = usage[0];
        longest.limitStale = YES; longest.limitUpdatedAt = [NSDate dateWithTimeIntervalSinceNow:-10*3600];
        longest.limitWindows = @[
            @{@"remainingFraction":@1, @"window":@"5-hour", @"resetsAt":@(NSDate.date.timeIntervalSince1970 + 4*3600)},
            @{@"remainingFraction":@1, @"window":@"weekly", @"resetsAt":@(NSDate.date.timeIntervalSince1970 + 6.5*86400)},
            @{@"remainingFraction":@1, @"window":@"weekly Fable"}];
        [c rebuildContent];
        if (!HasText(p.contentViewController.view, @"stale 10h") || !FitsChildren(p.contentViewController.view)) {
            DumpClaudeCaption(p.contentViewController.view); return Fail(__LINE__);
        }
        longest.limitStale = NO; longest.limitUpdatedAt = nil;
        longest.limitWindows = @[
            @{@"remainingFraction":@0.57, @"window":@"5-hour", @"resetsAt":@(NSDate.date.timeIntervalSince1970 + 7200)},
            @{@"remainingFraction":@0.33, @"window":@"weekly", @"resetsAt":@(NSDate.date.timeIntervalSince1970 + 86400)},
            @{@"remainingFraction":@0.06, @"window":@"weekly Fable"}];
        [c rebuildContent];
        if (!HasTip(root, @"Macintosh HD")) return Fail(__LINE__);
        AIUsage *history = usage[0];
        history.todayTokens = 268000;
        history.weekTokens = 11200000;
        AIUsage *codexHistory = usage[1];
        codexHistory.todayTokens = 20800000;
        codexHistory.weekTokens = 52800000;
        // Real multi-million readings and the largest stored total must fit in
        // one row, with no ellipsis and no overlap between label/value columns.
        for (NSNumber *count in @[@0, @999, @999499, @20800000, @999499999, @999499999999LL, @(LLONG_MAX)]) {
            AIUsage *sample = [AIUsage new]; sample.name = @"Codex";
            sample.todayTokens = count.longLongValue; sample.weekTokens = MAX(1, count.longLongValue);
            NSView *doc = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,kDetailW,32)];
            [c addDetailHistory:sample to:doc y:0 cols:DetailLayout(kDetailW)];
            if (!FitsChildren(doc)) return Fail(__LINE__);
            NSArray *columns = @[@"metric", @"today", @"todayLabel", @"value", @"weekLabel"];
            CGFloat previousRight = 0;
            for (NSString *column in columns) {
                NSView *field = FindIdentifier(doc, [@"details.ai.history.codex." stringByAppendingString:column]);
                if (!field || NSMinX(field.frame) < previousRight || field.toolTip.length) return Fail(__LINE__);
                previousRight = NSMaxX(field.frame);
            }
        }
        history.todaySessions = 2;
        history.weekSessions = 9;
        NSArray *sampleApps = @[
            @{@"name": @"WindowServer", @"impact": @50, @"cpu": @120, @"bytes": @(6ULL << 30)},
            @{@"name": @"kernel_task", @"impact": @30, @"cpu": @80, @"bytes": @(4ULL << 30)},
            @{@"name": @"nsurlsessiond", @"impact": @20, @"cpu": @40, @"bytes": @(2ULL << 30)},
        ];
        [c setValue:sampleApps forKey:@"hogs"];
        [c setValue:sampleApps forKey:@"topCPU"];
        [c setValue:sampleApps forKey:@"topMem"];
        NSScrollView *overview = [c overviewDetailsView];
        NSScrollView *storage = [c storageDetailsView];
        NSScrollView *battery = [c batteryDetailsView];
        NSScrollView *system = [c systemDetailsView];
        NSScrollView *ai = [c aiDetailsView];
        if (!HasText(storage.documentView, @"External 6")) return Fail(__LINE__);
        if (!HasText(ai.documentView, @"week") || !HasText(ai.documentView, @"5h") ||
            !HasText(ai.documentView, @"Fable") || !HasTip(ai.documentView, @"weekly")) return Fail(__LINE__);
        if (HasText(ai.documentView, @"weekly")) return Fail(__LINE__);
        NSArray *docs = @[overview.documentView, storage.documentView, battery.documentView,
                          system.documentView, ai.documentView];
        for (NSView *doc in docs) if (DetailFiller(doc)) return Fail(__LINE__);
        if (HasText(storage.documentView, @"Volume scan unavailable")) return Fail(__LINE__);
        if (!HasTip(storage.documentView, @"Volume scan unavailable")) return Fail(__LINE__);
        NSUInteger volumeCount = [[c valueForKey:@"vols"] count];
        NSUInteger storageRows = 0;
        for (NSUInteger i = 0; i < volumeCount; i++) {
            NSString *ident = [NSString stringWithFormat:@"details.storage.row.%lu", (unsigned long)i];
            NSView *row = FindIdentifier(storage.documentView, ident);
            if (CountIdentifier(storage.documentView, ident) != 1 || !row || row.frame.size.height > 36)
                return Fail(__LINE__);
            storageRows++;
        }
        if (storageRows != volumeCount) return Fail(__LINE__);
        NSView *stored = FindIdentifier(storage.documentView, @"details.storage.row.0");
        NSButton *reveal = nil;
        for (NSView *sub in stored.subviews) if ([sub isKindOfClass:NSButton.class]) reveal = (NSButton *)sub;
        if (!reveal || reveal.title.length || !reveal.image || ![reveal.accessibilityHelp isEqualToString:@"Reveal in Finder"])
            return Fail(__LINE__);
        NSView *provider = FindIdentifier(ai.documentView, @"details.ai.row.claude");
        NSView *windowRow = FindIdentifier(ai.documentView, @"details.ai.window.claude.0");
        NSView *providerGauge = FirstGauge(provider);
        NSView *windowGauge = FirstGauge(windowRow);
        if (!providerGauge || !windowGauge ||
            fabs(providerGauge.frame.origin.x - windowGauge.frame.origin.x) > 0.5) return Fail(__LINE__);
        for (NSString *slug in @[@"codex", @"cursor"]) {
            NSView *prow = FindIdentifier(ai.documentView, [@"details.ai.row." stringByAppendingString:slug]);
            NSView *wrow = FindIdentifier(ai.documentView, [NSString stringWithFormat:@"details.ai.window.%@.0", slug]);
            if (!prow || !wrow || fabs(FirstGauge(prow).frame.origin.x - FirstGauge(wrow).frame.origin.x) > 0.5)
                return Fail(__LINE__);
        }
        if (!DetailColumnsMatch(docs)) return Fail(__LINE__);
        NSTextField *etaName = (NSTextField *)FindIdentifier(battery.documentView, @"details.battery.eta.name");
        NSTextField *etaValue = (NSTextField *)FindIdentifier(battery.documentView, @"details.battery.eta.arrivals");
        // The charge wattage is said once, on the Charge row: no "at +12 W" echo here, and
        // the Mac's draw and charge share one flow bar instead of three text rows.
        BatteryForecast detailsForecast = [c batteryForecast];
        NSString *expectedArrivals = BatteryForecastDetail(detailsForecast, NSDate.date.timeIntervalSince1970, nil);
        if (detailsForecast.hypotheticalFull) expectedArrivals = [expectedArrivals stringByAppendingString:@" · 100% if limit off"];
        if (![etaName.stringValue isEqual:@"Forecast"] || ![etaValue.stringValue isEqual:expectedArrivals] ||
            FindIdentifier(battery.documentView, @"details.battery.eta.datum") ||
            FindIdentifier(battery.documentView, @"details.battery.row.power") ||
            FindIdentifier(battery.documentView, @"details.battery.row.load"))
            return Fail(__LINE__);
        PowerFlowGauge *flowBar = (PowerFlowGauge *)FindIdentifier(battery.documentView, @"details.battery.input.gauge");
        if (flowBar && (![flowBar isKindOfClass:PowerFlowGauge.class] || !flowBar.accessibilityHelp.length)) return Fail(__LINE__);
        // System: CPU is the bar; memory in use is the thin line inside it (Cursor's language).
        // No words or unexplained glyphs beside it.
        for (NSView *doc in @[root, overview.documentView]) {
            NSString *stem = doc == root ? @"popover.system" : @"details.overview.system";
            Gauge *cpuBar = (Gauge *)FindIdentifier(doc, [stem stringByAppendingString:@".gauge"]);
            if (![cpuBar isKindOfClass:Gauge.class] || cpuBar.innerFraction >= 0 ||
                FindIdentifier(doc, [stem stringByAppendingString:@".datum"]) ||
                FindIdentifier(doc, [stem stringByAppendingString:@".memory.symbol"])) return Fail(__LINE__);
        }
        NSArray *etaFields = @[etaName, etaValue];
        for (NSTextField *field in etaFields) {
            if (![field isKindOfClass:NSTextField.class]) return Fail(__LINE__);
            CGFloat textW = [field.stringValue sizeWithAttributes:@{NSFontAttributeName: field.font}].width;
            if (textW > field.bounds.size.width - 2) {
                fprintf(stderr, "truncated %s (%.1f > %.1f)\n", field.accessibilityIdentifier.UTF8String,
                        textW, field.bounds.size.width);
                return Fail(__LINE__);
            }
        }
        NSTextField *volumeName = (NSTextField *)FindIdentifier(overview.documentView, @"details.overview.storage.name");
        NSTextField *batteryName = (NSTextField *)FindIdentifier(overview.documentView, @"details.overview.battery.name");
        NSTextField *systemName = (NSTextField *)FindIdentifier(overview.documentView, @"details.overview.system.name");
        if (![volumeName.stringValue isEqual:@"Macintosh HD"] || ![batteryName.stringValue isEqual:@"Battery"] ||
            ![systemName.stringValue isEqual:@"System"] || !SameColumn(volumeName, batteryName) ||
            !SameColumn(volumeName, systemName)) return Fail(__LINE__);
        NSTextField *detailClaude = (NSTextField *)FindIdentifier(ai.documentView, @"details.ai.claude.name");
        NSTextField *overviewClaude = (NSTextField *)FindIdentifier(overview.documentView, @"details.overview.ai.claude.name");
        if (![detailClaude.stringValue isEqual:@"Claude"] || ![overviewClaude.stringValue isEqual:@"Claude"] ||
            !SameColumn(volumeName, detailClaude) || !SameColumn(volumeName, overviewClaude))
            return Fail(__LINE__);
        NSTextField *windowDatum = (NSTextField *)FindIdentifier(ai.documentView, @"details.ai.window.claude.0.datum");
        NSTextField *providerDatum = (NSTextField *)FindIdentifier(ai.documentView, @"details.ai.claude.datum");
        if (![windowDatum.stringValue hasPrefix:@"resets "] || ![providerDatum.stringValue hasPrefix:@"resets "])
            return Fail(__LINE__);
        Gauge *fullWindow = (Gauge *)FindIdentifier(ai.documentView, @"details.ai.window.codex.1.gauge");
        Gauge *lowWindow = (Gauge *)FindIdentifier(ai.documentView, @"details.ai.window.codex.0.gauge");
        Gauge *overviewCharge = (Gauge *)FindIdentifier(overview.documentView, @"details.overview.battery.gauge");
        if (![fullWindow isKindOfClass:Gauge.class] || ![lowWindow isKindOfClass:Gauge.class] ||
            !ForecastFits((BatteryForecastView *)FindIdentifier(overview.documentView, @"details.overview.battery.forecast")) ||
            overviewCharge.markerFraction != -1) return Fail(__LINE__);
        __block BOOL fullGreen = NO, lowRed = NO;
        [[NSAppearance appearanceNamed:NSAppearanceNameAqua] performAsCurrentDrawingAppearance:^{
            fullGreen = Green([fullWindow.color colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace]);
            lowRed = Red([lowWindow.color colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace]);
        }];
        if (!fullGreen || !lowRed) return Fail(__LINE__);
        for (NSString *ident in @[@"details.overview.row.storage", @"details.overview.row.battery",
                                  @"details.overview.row.system", @"details.overview.row.ai.claude",
                                  @"details.overview.row.ai.codex", @"details.overview.row.ai.cursor"])
            if (!FindIdentifier(overview.documentView, ident)) return Fail(__LINE__);
        NSView *cpuGauge = FindIdentifier(system.documentView, @"details.system.cpu.gauge");
        NSView *cpuBar = FindIdentifier(system.documentView, @"details.system.bar.cpu.0.bar");
        if (!cpuBar || cpuBar.frame.size.height > 6 ||
            fabs(NSMaxX(cpuBar.frame) - NSMaxX(cpuGauge.frame)) > 0.5) return Fail(__LINE__);
        const char *musicState = getenv("GLANCEBAR_MUSIC_STATE");
        if (musicState && strcmp(musicState, "playing") == 0) {
            [c setValue:@YES forKey:@"localMode"];
            [c setValue:@YES forKey:@"playbackKnown"];
            [c setValue:@YES forKey:@"playbackPlaying"];
            [c setValue:@"Midnight City" forKey:@"localTitle"];
            [c setValue:@"M83" forKey:@"localArtist"];
            [c setValue:@83 forKey:@"trackElapsed"];
            [c setValue:@243 forKey:@"trackDuration"];
            [c setValue:@[
                @{@"uid": @"speakers", @"name": @"MacBook Air Speakers",
                  @"transport": @(GlanceAudioTransportBuiltIn), @"outputChannels": @2, @"dataSource": @""},
                @{@"uid": @"bose", @"name": @"Bose Flex SoundLink",
                  @"transport": @(GlanceAudioTransportBluetooth), @"outputChannels": @2, @"dataSource": @""}
            ] forKey:@"audioDevices"];
            [c setValue:@"speakers" forKey:@"defaultOutputUID"];
            [c setValue:@"speakers" forKey:@"playerOutputUID"];
            [c setValue:@"MacBook Air Speakers" forKey:@"playerOutputName"];
            [c rebuildContent];
            root = p.contentViewController.view;
            NSView *playingOut = FindIdentifier(root, @"popover.sound");
            if (!SoundRow(root, @"Midnight City", @"M83", YES) || !FitsChildren(root) ||
                ![playingOut.accessibilityHelp containsString:@"Glancebar's player"] ||
                ![playingOut.accessibilityLabel isEqual:@"Player output, MacBook Air Speakers"] ||
                !FindIdentifier(root, @"popover.music.favorite") || !FindIdentifier(root, @"popover.music.thumbsup") ||
                !FindIdentifier(root, @"popover.music.thumbsdown"))
                return Fail(__LINE__);
            const char *musicRowPNG = getenv("GLANCEBAR_MUSIC_ROW_PNG");
            if (musicRowPNG && musicRowPNG[0]) {
                NSString *dir = [NSString stringWithUTF8String:musicRowPNG];
                [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                if (!RenderOffscreen(root, [dir stringByAppendingPathComponent:@"dislike-light.png"], NSAppearanceNameAqua) ||
                    !RenderOffscreen(root, [dir stringByAppendingPathComponent:@"dislike-dark.png"], NSAppearanceNameDarkAqua))
                    return Fail(__LINE__);
                NSString *fakeTrack = [fixtureMusic stringByAppendingPathComponent:@"midnight.m4a"];
                [@"silent" writeToFile:fakeTrack atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [c setValue:@[[NSURL fileURLWithPath:fakeTrack]] forKey:@"localURLs"];
                [c setValue:@[@{@"id": @"m83|midnight city", @"title": @"Midnight City", @"artist": @"M83",
                                 @"album": @"", @"local_path": fakeTrack}] forKey:@"stationTracks"];
                [c setValue:[NSMutableSet setWithObject:@"m83|midnight city"] forKey:@"mixDisliked"];
                [c rebuildContent];
                root = p.contentViewController.view;
                if (!RenderOffscreen(root, [dir stringByAppendingPathComponent:@"dislike-on-light.png"], NSAppearanceNameAqua))
                    return Fail(__LINE__);
            }
        } else if (musicState && strcmp(musicState, "idle") == 0) {
            [c setValue:@NO forKey:@"localMode"];
            [c setValue:@NO forKey:@"playbackKnown"];
            [c setValue:@NO forKey:@"playbackPlaying"];
            [c rebuildContent];
            root = p.contentViewController.view;
            if (!SoundRow(root, @"Liked Music", @"0 of 0 on this Mac", NO) || !FitsChildren(root))
                return Fail(__LINE__);
        } else if (musicState && strcmp(musicState, "apple") == 0) {
            [c setValue:@YES forKey:@"localMode"];
            [c setValue:@"kind:dance" forKey:@"mixPlayingKey"];
            [c setValue:@YES forKey:@"playbackKnown"];
            [c setValue:@YES forKey:@"playbackPlaying"];
            [c setValue:@"Lightning Crashes" forKey:@"localTitle"];
            [c setValue:@"LIVE" forKey:@"localArtist"];
            [c setValue:@83 forKey:@"trackElapsed"];
            [c setValue:@324 forKey:@"trackDuration"];
            [c rebuildContent];
            root = p.contentViewController.view;
            NSSlider *position = (NSSlider *)FindIdentifier(root, @"popover.music.position");
            NSTextField *elapsed = (NSTextField *)FindIdentifier(root, @"popover.music.elapsed");
            NSTextField *length = (NSTextField *)FindIdentifier(root, @"popover.music.duration");
            NSButton *heart = (NSButton *)FindIdentifier(root, @"popover.music.favorite");
            if (!SoundRow(root, @"Lightning Crashes", @"LIVE", YES) || !FitsChildren(root) ||
                ![position isKindOfClass:NSSlider.class] || fabs(position.doubleValue - 83) > 1 ||
                ![elapsed.stringValue isEqual:@"1:23"] || ![length.stringValue isEqual:@"5:24"] ||
                ![heart.accessibilityLabel isEqual:@"Add to Favourites"] ||
                FindIdentifier(root, @"popover.music.shuffle") ||
                FindIdentifier(root, @"popover.music.open"))
                return Fail(__LINE__);
            {   // 👎👍♥ sit at the row's right edge and don't crowd the title.
                NSView *thumb = FindIdentifier(root, @"popover.music.thumbsup");
                NSView *thumbsdown = FindIdentifier(root, @"popover.music.thumbsdown");
                NSView *title = FindIdentifier(root, @"popover.music.title");
                if (!thumb || !thumbsdown || NSMaxX(thumb.frame) > NSMinX(heart.frame) + 0.5 ||
                    NSMaxX(thumbsdown.frame) > NSMinX(thumb.frame) + 0.5 ||
                    NSMaxX(title.frame) > NSMinX(thumbsdown.frame) - 6 + 0.5 ||
                    ![thumb.accessibilityLabel hasPrefix:@"Thumbs-up"] ||
                    ![thumbsdown.accessibilityLabel isEqual:@"Dislike: skip this and never play it again"]) return Fail(__LINE__);
            }
            if (argc > 1) {
                NSString *stem = [[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension];
                NSAppearanceName look = argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
                if (!RenderOffscreen(root, [stem stringByAppendingString:@"-music.png"], look)) return Fail(__LINE__);
            }
            // The scrubber line is the only extra height; later fixtures measure the idle panel.
            [c setValue:@NO forKey:@"localMode"];
            [c setValue:nil forKey:@"mixPlayingKey"];
            [c setValue:@NO forKey:@"playbackKnown"];
            [c setValue:@NO forKey:@"playbackPlaying"];
        } else if (musicState && strcmp(musicState, "station") == 0) {
            id oldDevices = [c valueForKey:@"audioDevices"];
            id oldUID = [c valueForKey:@"defaultOutputUID"];
            [c setValue:@YES forKey:@"localMode"];
            [c setValue:@"station:triplej" forKey:@"mixPlayingKey"];
            [c setValue:@YES forKey:@"playbackKnown"];
            [c setValue:@YES forKey:@"playbackPlaying"];
            [c setValue:@"Kiss from a Rose" forKey:@"localTitle"];
            [c setValue:@"Tame Impala" forKey:@"localArtist"];
            [c setValue:@83 forKey:@"trackElapsed"];
            [c setValue:@243 forKey:@"trackDuration"];
            [c setValue:@0 forKey:@"localIndex"];
            [c setValue:@[[NSURL fileURLWithPath:stationFixture]] forKey:@"localURLs"];
            [c setValue:@[@{@"file": stationFixture, @"artist": @"Tame Impala",
                            @"title": @"Kiss from a Rose", @"key": @"tame impala|kiss from a rose"}] forKey:@"stationTracks"];
            [c setValue:@[
                @{@"uid": @"speakers", @"name": @"MacBook Air Speakers",
                  @"transport": @(GlanceAudioTransportBuiltIn), @"outputChannels": @2, @"dataSource": @""}
            ] forKey:@"audioDevices"];
            [c setValue:@"speakers" forKey:@"defaultOutputUID"];
            [c rebuildContent];
            root = p.contentViewController.view;
            NSButton *heart = (NSButton *)FindIdentifier(root, @"popover.music.favorite");
            NSButton *thumb = (NSButton *)FindIdentifier(root, @"popover.music.thumbsup");
            NSButton *thumbsdown = (NSButton *)FindIdentifier(root, @"popover.music.thumbsdown");
            NSView *title = FindIdentifier(root, @"popover.music.title");
            if (!SoundRow(root, @"Kiss from a Rose", @"Tame Impala", YES) || !FitsChildren(root) ||
                ![heart isKindOfClass:NSButton.class] || ![thumb isKindOfClass:NSButton.class] ||
                ![thumbsdown isKindOfClass:NSButton.class] ||
                ![heart.accessibilityLabel isEqual:@"Add to Favourites"] ||
                ![thumb.accessibilityLabel isEqual:@"Thumbs-up: mixes should play more like this"] ||
                ![thumbsdown.accessibilityLabel isEqual:@"Dislike: skip this and never play it again"] ||
                fabs(NSWidth(heart.frame) - 22) > 0.5 || fabs(NSHeight(heart.frame) - 22) > 0.5 ||
                fabs(NSWidth(thumb.frame) - 22) > 0.5 || fabs(NSHeight(thumb.frame) - 22) > 0.5 ||
                fabs(NSWidth(thumbsdown.frame) - 22) > 0.5 || fabs(NSHeight(thumbsdown.frame) - 22) > 0.5 ||
                NSMaxX(thumb.frame) > NSMinX(heart.frame) + 0.5 || NSMaxX(thumbsdown.frame) > NSMinX(thumb.frame) + 0.5 ||
                NSMaxX(title.frame) > NSMinX(thumbsdown.frame) - 6 + 0.5)
                return Fail(__LINE__);
            [c setValue:[NSMutableSet setWithObject:@"tame impala|kiss from a rose"] forKey:@"heartedKeys"];
            [c rebuildContent];
            root = p.contentViewController.view;
            heart = (NSButton *)FindIdentifier(root, @"popover.music.favorite");
            if (![heart.accessibilityLabel isEqual:@"Remove from Favourites"]) return Fail(__LINE__);
            [c setValue:[NSMutableSet set] forKey:@"heartedKeys"];
            [c setValue:@"kind:alt" forKey:@"mixPlayingKey"];
            [c rebuildContent];
            root = p.contentViewController.view;
            if (!FindIdentifier(root, @"popover.music.favorite") || !FindIdentifier(root, @"popover.music.thumbsup") ||
                !FindIdentifier(root, @"popover.music.thumbsdown"))
                return Fail(__LINE__);
            [c setValue:@NO forKey:@"localMode"];
            [c setValue:@"" forKey:@"mixPlayingKey"];
            [c rebuildContent];
            root = p.contentViewController.view;
            if (FindIdentifier(root, @"popover.music.favorite") || FindIdentifier(root, @"popover.music.thumbsup") ||
                FindIdentifier(root, @"popover.music.thumbsdown"))
                return Fail(__LINE__);
            [c setValue:@YES forKey:@"localMode"];
            [c setValue:@"station:triplej" forKey:@"mixPlayingKey"];
            [c rebuildContent];
            root = p.contentViewController.view;
            if (argc > 1) {
                gStationRender = YES;
                NSAppearanceName look = argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
                if (!RenderOffscreen(root, [NSString stringWithUTF8String:argv[1]], look)) return Fail(__LINE__);
            }
            [c setValue:@NO forKey:@"localMode"];
            [c setValue:nil forKey:@"mixPlayingKey"];
            [c setValue:@NO forKey:@"playbackKnown"];
            [c setValue:@NO forKey:@"playbackPlaying"];
            [c setValue:nil forKey:@"localTitle"];
            [c setValue:nil forKey:@"localArtist"];
            [c setValue:nil forKey:@"localURLs"];
            [c setValue:nil forKey:@"stationTracks"];
            [c setValue:nil forKey:@"heartedKeys"];
            [c setValue:oldDevices forKey:@"audioDevices"];
            [c setValue:oldUID forKey:@"defaultOutputUID"];
            [c rebuildContent];
            root = p.contentViewController.view;
        } else if (musicState && (strcmp(musicState, "shows-row") == 0 || strcmp(musicState, "shows-playing") == 0)) {
            NSTimeZone *utc = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            NSDate *day = [NSDate dateWithTimeIntervalSince1970:1763107200];
            NSString *showDir = [fixtureMusic stringByAppendingPathComponent:@"House Party"];
            [NSFileManager.defaultManager createDirectoryAtPath:showDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *epA = [showDir stringByAppendingPathComponent:@"2026-11-14-ep1.m4a"];
            NSString *epB = [showDir stringByAppendingPathComponent:@"2026-11-07-ep2.m4a"];
            NSString *epC = [showDir stringByAppendingPathComponent:@"2026-11-01-ep3.m4a"];
            if (!WriteSilentM4A(epA, @"Marita Lee", FixtureCoverPNG(0.52), 120) ||
                !WriteSilentM4A(epB, @"Marita Lee", FixtureCoverPNG(0.56), 120) ||
                !WriteSilentM4A(epC, @"Marita Lee", FixtureCoverPNG(0.48), 120))
                return Fail(__LINE__);
            NSMutableArray *pickPaths = [NSMutableArray array];
            for (NSUInteger i = 0; i < 4; i++) {
                NSString *p = [fixtureMusic stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"new-music-%lu.m4a", (unsigned long)i]];
                if (!WriteSilentM4A(p, @"Pick Artist", FixtureCoverPNG(0.08 + 0.14 * i), 0.1)) return Fail(__LINE__);
                [pickPaths addObject:p];
            }
            NSMutableArray *stationTracks = [NSMutableArray array];
            for (NSUInteger i = 0; i < 4; i++)
                [stationTracks addObject:@{@"id": [NSString stringWithFormat:@"pick-%lu", (unsigned long)i],
                                          @"title": @"Pick", @"artist": @"Artist", @"album": @"", @"local_path": pickPaths[i]}];
            [c setValue:stationTracks forKey:@"stationTracks"];
            [c setValue:@[
                @{@"title": @"One", @"artist": @"A", @"reason": @"", @"file": pickPaths[0]},
                @{@"title": @"Two", @"artist": @"B", @"reason": @"", @"file": pickPaths[1]},
                @{@"title": @"Three", @"artist": @"C", @"reason": @"", @"file": pickPaths[2]},
                @{@"title": @"Four", @"artist": @"D", @"reason": @"", @"file": pickPaths[3]}
            ] forKey:@"stationPicks"];
            NSString *fbPath = [fixtureHome stringByAppendingPathComponent:@"Library/Application Support/Glancebar/mix/feedback.jsonl"];
            [NSFileManager.defaultManager createDirectoryAtPath:[fbPath stringByDeletingLastPathComponent]
                                    withIntermediateDirectories:YES attributes:nil error:nil];
            [@"" writeToFile:fbPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [c rebuildContent];
            root = p.contentViewController.view;
            double savedDur = (strcmp(musicState, "shows-playing") == 0) ? 14400.0 : 240.0;
            NSDictionary *showsState = @{@"version": @1, @"episodes": @{
                epA: @{@"position": @72, @"duration": @(savedDur), @"finished": @NO, @"updated": @"2026-11-14T09:00:00Z"},
                epB: @{@"position": @0, @"duration": @(savedDur), @"finished": @NO, @"updated": @"2026-11-07T09:00:00Z"},
                epC: @{@"position": @0, @"duration": @(savedDur), @"finished": @NO, @"updated": @"2026-11-01T09:00:00Z"}}};
            NSString *showsPath = [fixtureHome stringByAppendingPathComponent:@"Library/Application Support/Glancebar/mix/shows.json"];
            [ShowsStateToJSON(showsState) writeToFile:showsPath atomically:YES];
            NSArray *episodes = @[
                @{@"path": epA, @"show": @"House Party", @"presenter": @"Marita Lee", @"broadcast": day, @"sortDate": day, @"duration": @(savedDur)},
                @{@"path": epB, @"show": @"House Party", @"presenter": @"Marita Lee", @"broadcast": day, @"sortDate": day, @"duration": @(savedDur)},
                @{@"path": epC, @"show": @"House Party", @"presenter": @"Marita Lee", @"broadcast": day, @"sortDate": day, @"duration": @(savedDur)}];
            NSDictionary *offer = ShowsPickOfferedEpisode(episodes, showsState);
            [c setValue:@YES forKey:@"musicProbesEnabled"];
            [c setValue:@YES forKey:@"musicSilentQA"];
            [c setValue:@YES forKey:@"showsLoaded"];
            [c setValue:episodes forKey:@"showEpisodes"];
            [c setValue:offer forKey:@"showOffered"];
            [c setValue:showsState forKey:@"showsState"];
            [c setValue:[NSMutableDictionary dictionary] forKey:@"showCoverCache"];
            [c setValue:[NSMutableDictionary dictionary] forKey:@"stationCoverCache"];
            if (![c embeddedArtworkForPath:epA] || [c stationMosaicCovers].count < 4) return Fail(__LINE__);
            [c rebuildContent];
            root = p.contentViewController.view;
            GBShowTile *show = (GBShowTile *)FindIdentifier(root, @"popover.music.show");
            GBStationTile *station = (GBStationTile *)FindIdentifier(root, @"popover.mix.station");
            NSTextField *showCap = (NSTextField *)FindIdentifier(root, @"popover.music.show.caption");
            NSTextField *showSub = (NSTextField *)FindIdentifier(root, @"popover.music.show.artist");
            NSTextField *nmCap = (NSTextField *)FindIdentifier(root, @"popover.mix.caption.4");
            GBShowProgressView *prog = (GBShowProgressView *)FindIdentifier(root, @"popover.music.show.progress");
            NSView *showMark = FindIdentifier(root, @"popover.music.show.typemark");
            NSView *stMark = FindIdentifier(root, @"popover.mix.station.typemark");
            NSDictionary *counts = @{@"dance": @2, @"alt": @2, @"rap": @2, @"chill": @1};
            if (!show || !station || !showCap || !showSub || !nmCap || !prog ||
                MixRowHasLegacySeedTiles(root) || !KindMixRowLayoutOK(root, 6, 50) ||
                !KindMixRowOK(root, 6, 50, counts, nil) || !FitsChildren(root))
                return Fail(__LINE__);
            NSView *chill = KindTileButton(root, @"chill");
            if (NSMinX(show.frame) <= NSMaxX(chill.frame) + 0.5 || NSMinX(station.frame) <= NSMaxX(show.frame) + 0.5)
                return Fail(__LINE__);
            if (![showCap.stringValue isEqual:@"House Party"] || ![nmCap.stringValue isEqual:@"New music"] ||
                ![ShowTileCaptionLine2(day, @"Marita Lee", utc) isEqual:showSub.stringValue])
                return Fail(__LINE__);
            if (!CaptionFits(showCap) || !CaptionFits(showSub) || !CaptionFits(nmCap)) return Fail(__LINE__);
            // The label's own test for "clipped" sets a tooltip with the full text: none here.
            if (showCap.toolTip.length || showSub.toolTip.length || nmCap.toolTip.length) return Fail(__LINE__);
            if (fabs(prog.fraction - (72.0 / savedDur)) > 0.05) return Fail(__LINE__);
            // The bar is on the cover's bottom edge (the button's coordinates are flipped).
            if (fabs(NSMaxY(prog.frame) - NSHeight(show.bounds)) > 1.0 || NSHeight(prog.frame) > 3.5) return Fail(__LINE__);
            // Type marks sit at the top-left of their covers; the badge is top-right.
            if (!stMark || fabs(NSMaxY(stMark.frame) - (NSMaxY(station.frame) - 3)) > 1.5 ||
                fabs(NSMinX(stMark.frame) - (NSMinX(station.frame) + 3)) > 1.5) return Fail(__LINE__);
            if (!showMark || fabs(NSMinY(showMark.frame) - 3) > 1.5 || fabs(NSMinX(showMark.frame) - 3) > 1.5) return Fail(__LINE__);
            if ([c stationMosaicCovers].count < 4) return Fail(__LINE__);
            const char *musicRowPNG = getenv("GLANCEBAR_MUSIC_ROW_PNG");
            if (musicRowPNG && musicRowPNG[0] && strcmp(musicState, "shows-row") == 0) {
                NSString *dir = [NSString stringWithUTF8String:musicRowPNG];
                [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                if (!RenderOffscreen(root, [dir stringByAppendingPathComponent:@"show-tile-light.png"], NSAppearanceNameAqua) ||
                    !RenderOffscreen(root, [dir stringByAppendingPathComponent:@"show-tile-dark.png"], NSAppearanceNameDarkAqua))
                    return Fail(__LINE__);
            }
            if (strcmp(musicState, "shows-row") == 0) {
                [c playShow:show];
                for (int spin = 0; spin < 30; spin++)
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                if (![[c valueForKey:@"localMode"] boolValue] || ![[c valueForKey:@"mixPlayingKey"] isEqual:@"show:episode"])
                    return Fail(__LINE__);
                [c rebuildContent];
                root = p.contentViewController.view;
                NSTextField *elapsed = (NSTextField *)FindIdentifier(root, @"popover.music.elapsed");
                if (!elapsed || ![elapsed.stringValue containsString:@":"]) return Fail(__LINE__);
                double pos = 0;
                NSScanner *scan = [NSScanner scannerWithString:elapsed.stringValue];
                int m = 0, s = 0;
                if ([scan scanString:@"0:" intoString:NULL] || [scan scanInt:&m]) {
                    if ([scan scanString:@":" intoString:NULL]) [scan scanInt:&s];
                    pos = m * 60 + s;
                }
                if (pos < 62 || pos > 72) return Fail(__LINE__);
                [c musicPlay:nil];
                for (int spin = 0; spin < 20; spin++)
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                [c saveShowPositionNow];
                NSString *jsonPath = [c showsJSONPath];
                NSString *saved = [NSString stringWithContentsOfFile:jsonPath encoding:NSUTF8StringEncoding error:nil];
                if (!saved.length || ![saved containsString:@"House Party"] || ![saved containsString:@"\"position\""])
                    return Fail(__LINE__);
                [c rebuildContent];
                root = p.contentViewController.view;
                if (FindIdentifier(root, @"popover.music.favorite") || FindIdentifier(root, @"popover.music.thumbsup"))
                    return Fail(__LINE__);
                NSButton *thumbsDown = (NSButton *)FindIdentifier(root, @"popover.music.thumbsdown");
                NSView *title = FindIdentifier(root, @"popover.music.title");
                if (!thumbsDown || FindIdentifier(root, @"popover.music.thumbsup") ||
                    NSMaxX(title.frame) > NSMinX(thumbsDown.frame) - 6 + 0.5)
                    return Fail(__LINE__);
                [c performMusicNextCutNow];
                for (int spin = 0; spin < 40; spin++)
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                if (![[c valueForKey:@"localURLs"][0] path] || ![[[c valueForKey:@"localURLs"][0] path] isEqual:epB])
                    return Fail(__LINE__);
                [c musicThumbsDown:nil];
                NSString *fb = [NSString stringWithContentsOfFile:fbPath encoding:NSUTF8StringEncoding error:nil];
                if ([fb containsString:@"dislike"] || [fb containsString:@"event"]) return Fail(__LINE__);
                NSString *after = [NSString stringWithContentsOfFile:jsonPath encoding:NSUTF8StringEncoding error:nil];
                if (![after containsString:@"\"finished\":true"] && ![after containsString:@"\"finished\": true"])
                    return Fail(__LINE__);
            }
            if (strcmp(musicState, "shows-playing") == 0) {
                [c setValue:@YES forKey:@"localMode"];
                [c setValue:@YES forKey:@"playbackKnown"];
                [c setValue:@YES forKey:@"playbackPlaying"];
                [c setValue:@"show:episode" forKey:@"mixPlayingKey"];
                [c setValue:@"House Party" forKey:@"localTitle"];
                [c setValue:ShowNowPlayingSubtitle(day, @"Marita Lee", utc) forKey:@"localArtist"];
                [c setValue:@[[NSURL fileURLWithPath:epA]] forKey:@"localURLs"];
                [c setValue:@0 forKey:@"localIndex"];
                [c playShow:show];
                for (int spin = 0; spin < 40; spin++)
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                [c updateShowEpisodeState:epA position:67 duration:14400 finished:NO];
                [c noteLocalPlaybackTime];
                [c rebuildContent];
                root = p.contentViewController.view;
                show = (GBShowTile *)FindIdentifier(root, @"popover.music.show");
                if (!show || show.layer.borderWidth < 1.5) return Fail(__LINE__);
                NSTextField *elapsed = (NSTextField *)FindIdentifier(root, @"popover.music.elapsed");
                NSTextField *length = (NSTextField *)FindIdentifier(root, @"popover.music.duration");
                NSSlider *position = (NSSlider *)FindIdentifier(root, @"popover.music.position");
                if (!elapsed || !length || !position || position.maxValue < 3600 ||
                    ![length.stringValue containsString:@":"] || NSWidth(length.frame) < 48)
                    return Fail(__LINE__);
                if (FindIdentifier(root, @"popover.music.favorite") || FindIdentifier(root, @"popover.music.thumbsup"))
                    return Fail(__LINE__);
                const char *rowPNG = getenv("GLANCEBAR_MUSIC_ROW_PNG");
                if (rowPNG && rowPNG[0]) {
                    NSString *dir = [NSString stringWithUTF8String:rowPNG];
                    if (!RenderOffscreen(root, [dir stringByAppendingPathComponent:@"show-playing-light.png"], NSAppearanceNameAqua))
                        return Fail(__LINE__);
                }
            }
            [c tearDownLocalPlayer];
            [c setValue:nil forKey:@"showOffered"];
            [c setValue:@[] forKey:@"showEpisodes"];
            [c setValue:@NO forKey:@"showsLoaded"];
            [c setValue:[NSMutableDictionary dictionary] forKey:@"showCoverCache"];
            [c rebuildContent];
        } else if (musicState && (strcmp(musicState, "kinds-render") == 0 || strcmp(musicState, "kinds-five") == 0 ||
                                  strcmp(musicState, "kinds-empty") == 0)) {
            BOOL withShow = strcmp(musicState, "kinds-render") == 0;
            BOOL chillEmpty = strcmp(musicState, "kinds-empty") == 0;
            if (chillEmpty) {
                NSDictionary *emptyPack = KindHarnessTracks(fixtureMusic, NO);
                if (!emptyPack) return Fail(__LINE__);
                [c setValue:emptyPack[@"library"] forKey:@"mixLibrary"];
                NSDictionary *liveManifest = [c valueForKey:@"offlineManifest"];
                [c setValue:ManifestReplacingKindHarness(liveManifest, emptyPack[@"manifest"]) forKey:@"offlineManifest"];
                [c setValue:nil forKey:@"_onDiskLibraryIDs"];
                [c setValue:nil forKey:@"_kindTileSnapshot"];
            }
            NSMutableArray *picks8 = [NSMutableArray array];
            for (NSUInteger i = 0; i < 8; i++)
                [picks8 addObject:@{@"title": [NSString stringWithFormat:@"Pick %lu", (unsigned long)i],
                                   @"artist": @"Scout", @"reason": @"scout", @"file": @""}];
            [c setValue:picks8 forKey:@"stationPicks"];
            if (withShow) {
                NSDate *day = [NSDate dateWithTimeIntervalSince1970:1763107200];
                NSString *showDir = [fixtureMusic stringByAppendingPathComponent:@"Kinds Render Show"];
                [NSFileManager.defaultManager createDirectoryAtPath:showDir withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *epA = [showDir stringByAppendingPathComponent:@"2026-11-14-ep1.m4a"];
                NSString *epB = [showDir stringByAppendingPathComponent:@"2026-11-07-ep2.m4a"];
                NSString *epC = [showDir stringByAppendingPathComponent:@"2026-11-01-ep3.m4a"];
                if (!WriteSilentM4A(epA, @"Marita Lee", FixtureCoverPNG(0.52), 120) ||
                    !WriteSilentM4A(epB, @"Marita Lee", FixtureCoverPNG(0.56), 120) ||
                    !WriteSilentM4A(epC, @"Marita Lee", FixtureCoverPNG(0.48), 120))
                    return Fail(__LINE__);
                NSDictionary *showsState = @{@"version": @1, @"episodes": @{
                    epA: @{@"position": @72, @"duration": @240, @"finished": @NO, @"updated": @"2026-11-14T09:00:00Z"},
                    epB: @{@"position": @0, @"duration": @240, @"finished": @NO, @"updated": @"2026-11-07T09:00:00Z"},
                    epC: @{@"position": @0, @"duration": @240, @"finished": @NO, @"updated": @"2026-11-01T09:00:00Z"}}};
                NSString *showsPath = [fixtureHome stringByAppendingPathComponent:@"Library/Application Support/Glancebar/mix/shows.json"];
                [ShowsStateToJSON(showsState) writeToFile:showsPath atomically:YES];
                NSArray *episodes = @[
                    @{@"path": epA, @"show": @"House Party", @"presenter": @"Marita Lee", @"broadcast": day, @"sortDate": day, @"duration": @240},
                    @{@"path": epB, @"show": @"House Party", @"presenter": @"Marita Lee", @"broadcast": day, @"sortDate": day, @"duration": @240},
                    @{@"path": epC, @"show": @"House Party", @"presenter": @"Marita Lee", @"broadcast": day, @"sortDate": day, @"duration": @240}];
                [c setValue:@YES forKey:@"showsLoaded"];
                [c setValue:episodes forKey:@"showEpisodes"];
                [c setValue:ShowsPickOfferedEpisode(episodes, showsState) forKey:@"showOffered"];
                [c setValue:showsState forKey:@"showsState"];
                [c setValue:[NSMutableDictionary dictionary] forKey:@"showCoverCache"];
                [c setValue:@YES forKey:@"localMode"];
                [c setValue:@"kind:dance" forKey:@"mixPlayingKey"];
            } else {
                [c setValue:nil forKey:@"showOffered"];
                [c setValue:@[] forKey:@"showEpisodes"];
                [c setValue:@NO forKey:@"showsLoaded"];
            }
            [c rebuildContent];
            root = p.contentViewController.view;
            NSDictionary *counts = chillEmpty ? @{@"dance": @2, @"alt": @2, @"rap": @2, @"chill": @0}
                                              : @{@"dance": @2, @"alt": @2, @"rap": @2, @"chill": @1};
            NSUInteger tiles = withShow ? 6u : 5u;
            CGFloat side = withShow ? 50 : 54;
            NSString *playing = withShow ? @"dance" : nil;
            if (!KindMixRowOK(root, tiles, side, counts, playing) || !FitsChildren(root)) return Fail(__LINE__);
            if (withShow) {
                GBCountBadge *showBadge = (GBCountBadge *)FindIdentifier(root, @"popover.music.show.badge");
                NSView *stBadge = FindIdentifier(root, @"popover.mix.station.badge");
                if (!showBadge || showBadge.count != 2 || !stBadge ||
                    ![stBadge.accessibilityLabel isEqual:@"8 new picks"])
                    return Fail(__LINE__);
            }
            const char *rowPNG = getenv("GLANCEBAR_MUSIC_ROW_PNG");
            if (rowPNG && rowPNG[0]) {
                NSString *dir = [NSString stringWithUTF8String:rowPNG];
                [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                if (withShow) {
                    if (!RenderOffscreen(root, [dir stringByAppendingPathComponent:@"kind-tiles-light.png"], NSAppearanceNameAqua) ||
                        !RenderOffscreen(root, [dir stringByAppendingPathComponent:@"kind-tiles-dark.png"], NSAppearanceNameDarkAqua))
                        return Fail(__LINE__);
                } else if (strcmp(musicState, "kinds-five") == 0) {
                    if (!RenderOffscreen(root, [dir stringByAppendingPathComponent:@"kind-tiles-five-light.png"], NSAppearanceNameAqua))
                        return Fail(__LINE__);
                } else if (chillEmpty) {
                    GBKindTile *chill = (GBKindTile *)KindTileButton(root, @"chill");
                    if (chill.enabled || chill.alphaValue > 0.5) return Fail(__LINE__);
                    if (!RenderOffscreen(root, [dir stringByAppendingPathComponent:@"kind-tiles-empty-light.png"], NSAppearanceNameAqua))
                        return Fail(__LINE__);
                }
            }
        } else if (musicState && strcmp(musicState, "art-resolver") == 0) {
            [c setValue:@YES forKey:@"mixFrozen"];
            NSString *pa = [fixtureMusic stringByAppendingPathComponent:@"resolver-square.m4a"];
            NSString *pb = [fixtureMusic stringByAppendingPathComponent:@"resolver-wide.m4a"];
            NSString *folderAlbum = [fixtureMusic stringByAppendingPathComponent:@"resolver-folder-album"];
            NSString *lone = [fixtureMusic stringByAppendingPathComponent:@"resolver-none-dir"];
            [NSFileManager.defaultManager createDirectoryAtPath:folderAlbum withIntermediateDirectories:YES attributes:nil error:nil];
            [NSFileManager.defaultManager createDirectoryAtPath:lone withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *pc = [folderAlbum stringByAppendingPathComponent:@"track.m4a"];
            NSString *pd = [lone stringByAppendingPathComponent:@"track.m4a"];
            if (!WriteSilentM4A(pa, @"Fix Artist A", FixtureCoverPNG(0.2), 0.12) ||
                !WriteSilentM4A(pb, @"Fix Artist B", FixtureCoverWidePNG(0.35), 0.12) ||
                !WriteSilentM4A(pc, @"Fix Artist C", nil, 0.12) ||
                !WriteSilentM4A(pd, @"Fix Artist D", nil, 0.12))
                return Fail(__LINE__);
            if (![FixtureCoverPNG(0.42) writeToFile:[folderAlbum stringByAppendingPathComponent:@"cover.jpg"] atomically:YES])
                return Fail(__LINE__);
            NSImage *ia = [c trackCoverImageForTrackID:@"RA" artist:@"Fix Artist A" title:@"Square" album:@"" path:pa];
            NSImage *ib = [c trackCoverImageForTrackID:@"RB" artist:@"Fix Artist B" title:@"Wide" album:@"" path:pb];
            NSImage *ic = [c trackCoverImageForTrackID:@"RC" artist:@"Fix Artist C" title:@"Folder" album:@"" path:pc];
            NSImage *id_ = [c trackCoverImageForTrackID:@"RD" artist:@"Fix Artist D" title:@"None" album:@"" path:pd];
            if (!ia || !ib || !ic || id_) return Fail(__LINE__);
            if (fabs(ia.size.width - ia.size.height) > 2 || fabs(ib.size.width - ib.size.height) > 2) return Fail(__LINE__);
            NSString *keyA = TrackCoverCacheKey(@"RA", pa);
            NSString *keyB = TrackCoverCacheKey(@"RB", pb);
            NSString *artDir = [fixtureHome stringByAppendingPathComponent:@"Library/Application Support/Glancebar/mix/art"];
            if (![NSFileManager.defaultManager fileExistsAtPath:TrackCoverCacheJPEGPath(artDir, keyA)]) return Fail(__LINE__);
            if (![NSFileManager.defaultManager fileExistsAtPath:TrackCoverProvisionalMarkerPath(TrackCoverCacheJPEGPath(artDir, keyB))])
                return Fail(__LINE__);
            NSUInteger readsAfter = [c trackCoverEmbeddedReadCount];
            NSImage *ia2 = [c trackCoverImageForTrackID:@"RA" artist:@"Fix Artist A" title:@"Square" album:@"" path:pa];
            if (!ia2 || ![NSFileManager.defaultManager fileExistsAtPath:TrackCoverCacheJPEGPath(artDir, keyA)]) return Fail(__LINE__);
            if ([c trackCoverEmbeddedReadCount] != readsAfter) return Fail(__LINE__);
            MusicCoverNetworkState net; MusicCoverNetworkStateInit(&net);
            if (MusicCoverNetworkAllowsCatalogue(&net, 0, YES, YES, nil)) return Fail(__LINE__);
            NSDictionary *kindPack = KindHarnessTracks(fixtureMusic, YES);
            if (!kindPack) return Fail(__LINE__);
            [c setValue:kindPack[@"library"] forKey:@"mixLibrary"];
            [c setValue:ManifestReplacingKindHarness([c valueForKey:@"offlineManifest"], kindPack[@"manifest"]) forKey:@"offlineManifest"];
            [c setValue:nil forKey:@"_onDiskLibraryIDs"];
            [c setValue:nil forKey:@"_kindTileSnapshot"];
            NSArray *mosaic = [c kindMosaicCoversForIDs:@[@"KD1", @"KD2", @"KA1", @"KR1"]];
            if (mosaic.count < 4) return Fail(__LINE__);

            // Provisional upgrade: 16:9 provisional at once; fake catalogue replaces it.
            [c setValue:@NO forKey:@"mixFrozen"];
            [c setValue:@YES forKey:@"networkKnown"];
            [c setValue:@YES forKey:@"networkOnline"];
            NSString *widePath = [fixtureMusic stringByAppendingPathComponent:@"upgrade-wide.m4a"];
            if (!WriteSilentM4A(widePath, @"Upgrade Artist", FixtureCoverWidePNG(0.55), 0.12)) return Fail(__LINE__);
            NSString *keyU = TrackCoverCacheKey(@"RU", widePath);
            NSString *jpgU = TrackCoverCacheJPEGPath(artDir, keyU);
            NSString *markerU = TrackCoverProvisionalMarkerPath(jpgU);
            [c setValue:@YES forKey:@"mixFrozen"];
            NSImage *prov = [c trackCoverImageForTrackID:@"RU" artist:@"Upgrade Artist" title:@"Wide Song" album:@"" path:widePath];
            if (!prov || ![NSFileManager.defaultManager fileExistsAtPath:markerU]) return Fail(__LINE__);
            NSData *before = [NSData dataWithContentsOfFile:jpgU];
            [c setValue:@NO forKey:@"mixFrozen"];
            __block NSInteger catCalls = 0;
            NSData *catJSON = [@"{\"results\":[{\"artistName\":\"Upgrade Artist\",\"artworkUrl100\":\"https://example.invalid/100x100bb.jpg\"}]}"
                               dataUsingEncoding:NSUTF8StringEncoding];
            NSData *catJPEG = FixtureCoverPNG(0.71);
            [c setCoverCatalogueFetch:^NSData *(NSString *artist, NSString *title) {
                (void)artist; (void)title;
                catCalls++;
                return catJSON;
            }];
            [c setCoverImageFetch:^NSData *(NSURL *url) {
                (void)url;
                return catJPEG;
            }];
            [c setCoverClockOverride:5000];
            (void)[c trackCoverImageForTrackID:@"RU" artist:@"Upgrade Artist" title:@"Wide Song" album:@"" path:widePath];
            [c trackCoverKickNetworkWorker];
            CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 5.0;
            while (catCalls < 1 && CFAbsoluteTimeGetCurrent() < deadline) {
                [c trackCoverKickNetworkWorker];
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            if (catCalls < 1) return Fail(__LINE__);
            deadline = CFAbsoluteTimeGetCurrent() + 5.0;
            while ([NSFileManager.defaultManager fileExistsAtPath:markerU] && CFAbsoluteTimeGetCurrent() < deadline)
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            if ([NSFileManager.defaultManager fileExistsAtPath:markerU]) return Fail(__LINE__);
            NSData *after = [NSData dataWithContentsOfFile:jpgU];
            if (!after.length || [after isEqual:before]) return Fail(__LINE__);

            // Pacing: five catalogue lookups, 3s apart on the fake clock; no false misses.
            __block NSInteger paceCalls = 0;
            __block CFAbsoluteTime harnessClock = 8000;
            [c setCoverClockOverride:harnessClock];
            [c setCoverCatalogueFetch:^NSData *(NSString *artist, NSString *title) {
                paceCalls++;
                // Match whatever artist the worker asked for so MixArtURLFromSearch scores a hit.
                NSString *json = [NSString stringWithFormat:
                    @"{\"results\":[{\"artistName\":\"%@\",\"artworkUrl100\":\"https://example.invalid/100x100bb.jpg\"}]}",
                    artist ?: @"x"];
                (void)title;
                return [json dataUsingEncoding:NSUTF8StringEncoding];
            }];
            [c setCoverImageFetch:^NSData *(NSURL *url) { (void)url; return catJPEG; }];
            NSMutableArray *paceIDs = [NSMutableArray array];
            for (NSInteger i = 0; i < 5; i++) {
                NSString *p = [fixtureMusic stringByAppendingPathComponent:[NSString stringWithFormat:@"pace-%ld.m4a", (long)i]];
                if (!WriteSilentM4A(p, [NSString stringWithFormat:@"Pace %ld", (long)i], nil, 0.1)) return Fail(__LINE__);
                NSString *tid = [NSString stringWithFormat:@"PACE%ld", (long)i];
                [paceIDs addObject:@{@"tid": tid, @"path": p,
                                     @"artist": [NSString stringWithFormat:@"Pace %ld", (long)i]}];
                (void)[c trackCoverImageForTrackID:tid artist:paceIDs.lastObject[@"artist"]
                                             title:@"Song" album:@"" path:p];
            }
            // Wait until local misses have enqueued network work, then drain on the fake clock.
            deadline = CFAbsoluteTimeGetCurrent() + 5.0;
            while (CFAbsoluteTimeGetCurrent() < deadline) {
                [c trackCoverKickNetworkWorker];
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                if (paceCalls > 0) break;
            }
            deadline = CFAbsoluteTimeGetCurrent() + 15.0;
            harnessClock = 8000;
            while (paceCalls < 5 && CFAbsoluteTimeGetCurrent() < deadline) {
                NSInteger before = paceCalls;
                [c setCoverClockOverride:harnessClock];
                [c trackCoverKickNetworkWorker];
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                if (paceCalls == before) harnessClock += 3;
                else harnessClock = 8000 + paceCalls * 3;
            }
            if (paceCalls != 5) return Fail(__LINE__);
            (void)harnessClock;
            NSString *missPath = TrackCoverMissesPath(artDir);
            // A lookup that finds nothing is recorded and not retried inside the hour.
            __block NSInteger missCalls = 0;
            [c setCoverCatalogueFetch:^NSData *(NSString *a, NSString *t) {
                (void)a; (void)t; missCalls++;
                return [@"{\"results\":[]}" dataUsingEncoding:NSUTF8StringEncoding];
            }];
            [c setCoverImageFetch:^NSData *(NSURL *u) { (void)u; return nil; }];
            harnessClock = 9000;
            [c setCoverClockOverride:harnessClock];
            NSString *missTrack = [fixtureMusic stringByAppendingPathComponent:@"miss-track.m4a"];
            if (!WriteSilentM4A(missTrack, @"Miss Artist", nil, 0.1)) return Fail(__LINE__);
            // Empty track id so step 7 (Music.app) is not attempted if Music is running on this Mac.
            NSString *missKey = TrackCoverCacheKey(@"", missTrack);
            (void)[c trackCoverImageForTrackID:@"" artist:@"Miss Artist" title:@"Gone" album:@"" path:missTrack];
            deadline = CFAbsoluteTimeGetCurrent() + 8.0;
            while (missCalls < 1 && CFAbsoluteTimeGetCurrent() < deadline) {
                // Step the fake clock so a Wait from the pace drain cannot stall forever.
                harnessClock += 3;
                [c setCoverClockOverride:harnessClock];
                [c trackCoverKickNetworkWorker];
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            if (missCalls != 1) return Fail(__LINE__);
            deadline = CFAbsoluteTimeGetCurrent() + 3.0;
            while (![NSFileManager.defaultManager fileExistsAtPath:missPath] && CFAbsoluteTimeGetCurrent() < deadline)
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            if (![NSFileManager.defaultManager fileExistsAtPath:missPath]) return Fail(__LINE__);
            NSInteger callsAfter = missCalls;
            [c setCoverClockOverride:harnessClock + 100];
            (void)[c trackCoverImageForTrackID:@"" artist:@"Miss Artist" title:@"Gone" album:@"" path:missTrack];
            [c trackCoverKickNetworkWorker];
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
            if (missCalls != callsAfter) return Fail(__LINE__);
            // Miss file survives a new resolver instance (reload from disk).
            NSData *missData = [NSData dataWithContentsOfFile:missPath];
            NSMutableDictionary *reloaded = MusicCoverMissesFromJSON(missData, harnessClock + 100);
            if (!reloaded[[NSString stringWithFormat:@"cover:%@", missKey]])
                return Fail(__LINE__);
            [c setCoverCatalogueFetch:nil];
            [c setCoverImageFetch:nil];
            [c setCoverClockOverride:0];
        } else if (musicState && strcmp(musicState, "art-stress") == 0) {
            [c setValue:@NO forKey:@"mixFrozen"];
            [c setValue:@YES forKey:@"networkKnown"];
            [c setValue:@YES forKey:@"networkOnline"];
            NSMutableArray *library = [NSMutableArray array];
            NSMutableArray *manifestTracks = [NSMutableArray array];
            NSMutableArray *ids = [NSMutableArray array];
            for (NSUInteger i = 0; i < 40; i++) {
                NSString *tid = [NSString stringWithFormat:@"ST%02lu", (unsigned long)i];
                NSString *p = [fixtureMusic stringByAppendingPathComponent:[NSString stringWithFormat:@"stress-%@.m4a", tid]];
                NSData *cover = (i % 3 == 0) ? FixtureCoverWidePNG(0.05 * (i % 10))
                                             : FixtureCoverPNG(0.07 * (i % 12));
                if (!WriteSilentM4A(p, [NSString stringWithFormat:@"Stress %@", tid], cover, 0.1)) return Fail(__LINE__);
                [library addObject:@{@"id": tid, @"title": tid, @"artist": @"Stress", @"album": @"S",
                                     @"genre": @"Dance", @"plays": @(40 - (NSInteger)i), @"fav": @(i % 7 == 0),
                                     @"dislike": @NO, @"idleDays": @1}];
                [manifestTracks addObject:@{@"id": tid, @"path": p, @"title": tid, @"artist": @"Stress", @"album": @"S"}];
                [ids addObject:tid];
            }
            [c setValue:library forKey:@"mixLibrary"];
            NSDictionary *live = [c valueForKey:@"offlineManifest"] ?: @{@"schemaVersion": @1, @"playlists": @[]};
            NSMutableDictionary *manifest = [live mutableCopy];
            NSMutableArray *playlists = [[manifest[@"playlists"] isKindOfClass:NSArray.class] ? manifest[@"playlists"] : @[] mutableCopy];
            [playlists addObject:@{@"key": @"stress", @"tracks": manifestTracks, @"ready": @YES}];
            manifest[@"playlists"] = playlists;
            [c setValue:manifest forKey:@"offlineManifest"];
            [c setValue:nil forKey:@"_onDiskLibraryIDs"];
            [c setValue:nil forKey:@"_kindTileSnapshot"];
            [c setCoverCatalogueFetch:^NSData *(NSString *a, NSString *t) {
                (void)a; (void)t;
                return [@"{\"results\":[]}" dataUsingEncoding:NSUTF8StringEncoding];
            }];
            [c setCoverImageFetch:^NSData *(NSURL *u) { (void)u; return nil; }];
            [c scheduleCoverCacheWarm];
            for (NSUInteger r = 0; r < 50; r++) {
                [c rebuildContent];
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            }
            CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 30.0;
            BOOL allCached = NO;
            while (CFAbsoluteTimeGetCurrent() < deadline) {
                allCached = YES;
                for (NSString *tid in ids) {
                    NSDictionary *rec = nil;
                    for (NSDictionary *row in manifestTracks) if ([row[@"id"] isEqual:tid]) { rec = row; break; }
                    if (![c trackCoverHasCachedImageForTrackID:tid path:rec[@"path"]]) { allCached = NO; break; }
                }
                if (allCached) break;
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            if (!allCached) return Fail(__LINE__);
            [c setCoverCatalogueFetch:nil];
            [c setCoverImageFetch:nil];
        } else if (musicState && strcmp(musicState, "art-tiles-render") == 0) {
            // Frozen/synchronous resolve so every kind mosaic quarter has a picture before render.
            [c setValue:@YES forKey:@"mixFrozen"];
            NSDictionary *kindPack = KindHarnessTracks(fixtureMusic, YES);
            if (!kindPack) return Fail(__LINE__);
            [c setValue:kindPack[@"library"] forKey:@"mixLibrary"];
            [c setValue:ManifestReplacingKindHarness([c valueForKey:@"offlineManifest"], kindPack[@"manifest"]) forKey:@"offlineManifest"];
            [c setValue:nil forKey:@"_onDiskLibraryIDs"];
            [c setValue:nil forKey:@"_kindTileSnapshot"];
            for (NSDictionary *t in kindPack[@"library"]) {
                NSDictionary *rec = nil;
                for (id playlist in [c valueForKey:@"offlineManifest"][@"playlists"] ?: @[]) {
                    if (![playlist isKindOfClass:NSDictionary.class]) continue;
                    for (id row in playlist[@"tracks"] ?: @[])
                        if ([row isKindOfClass:NSDictionary.class] && [row[@"id"] isEqual:t[@"id"]]) { rec = row; break; }
                    if (rec) break;
                }
                NSString *path = [rec[@"path"] isKindOfClass:NSString.class] ? rec[@"path"] : @"";
                (void)[c trackCoverImageForTrackID:t[@"id"] artist:t[@"artist"] title:t[@"title"]
                                             album:t[@"album"] path:path];
            }
            NSMutableArray *stationTracks = [NSMutableArray array];
            for (NSUInteger i = 0; i < 4; i++) {
                NSString *p = [fixtureMusic stringByAppendingPathComponent:[NSString stringWithFormat:@"render-pick-%lu.m4a", (unsigned long)i]];
                if (!WriteSilentM4A(p, @"Render Picks", FixtureCoverPNG(0.05 + 0.17 * i), 0.1)) return Fail(__LINE__);
                [stationTracks addObject:@{@"id": [NSString stringWithFormat:@"RP%lu", (unsigned long)i], @"title": @"Pick",
                                          @"artist": @"Render", @"album": @"", @"local_path": p}];
                (void)[c trackCoverImageForTrackID:[NSString stringWithFormat:@"RP%lu", (unsigned long)i]
                                            artist:@"Render" title:@"Pick" album:@"" path:p];
            }
            [c setValue:stationTracks forKey:@"stationTracks"];
            [c setValue:nil forKey:@"_kindTileSnapshot"];
            [c rebuildContent];
            root = p.contentViewController.view;
            if ([c stationMosaicCovers].count < 4) return Fail(__LINE__);
            const char *rowPNG = getenv("GLANCEBAR_MUSIC_ROW_PNG");
            if (rowPNG && rowPNG[0]) {
                NSString *dir = [NSString stringWithUTF8String:rowPNG];
                [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                if (!RenderOffscreen(root, [dir stringByAppendingPathComponent:@"art-tiles-light.png"], NSAppearanceNameAqua) ||
                    !RenderOffscreen(root, [dir stringByAppendingPathComponent:@"art-tiles-dark.png"], NSAppearanceNameDarkAqua))
                    return Fail(__LINE__);
            }
        } else if (musicState && strcmp(musicState, "kinds-cached") == 0) {
            // Music has not been read in this run (it is closed, or the app has only just
            // started): the tiles come from the library's copy on disk.
            NSArray<NSDictionary *> *fixtureLibrary = [c valueForKey:@"mixLibrary"];
            NSString *cachePath = [c mixLibraryCachePath];
            NSString *mixDir = [fixtureHome stringByAppendingPathComponent:@"Library/Application Support/Glancebar/mix"];
            if (fixtureLibrary.count < 7 || ![cachePath isEqual:[mixDir stringByAppendingPathComponent:@"library.json"]])
                return Fail(__LINE__);
            NSMutableArray *picks8 = [NSMutableArray array];
            for (NSUInteger i = 0; i < 8; i++)
                [picks8 addObject:@{@"title": [NSString stringWithFormat:@"Pick %lu", (unsigned long)i],
                                   @"artist": @"Scout", @"reason": @"scout", @"file": @""}];
            [c setValue:picks8 forKey:@"stationPicks"];
            [c setValue:nil forKey:@"showOffered"];
            [c setValue:@[] forKey:@"showEpisodes"];
            [c setValue:@NO forKey:@"showsLoaded"];
            NSView *(^relaunched)(void) = ^NSView *{
                [c setValue:nil forKey:@"mixLibrary"];
                [c setValue:@NO forKey:@"mixLibraryCacheTried"];
                [c setValue:nil forKey:@"mixDisliked"];
                [c setValue:nil forKey:@"_onDiskLibraryIDs"];
                [c setValue:nil forKey:@"_kindTileSnapshot"];
                [c rebuildContent];
                return p.contentViewController.view;
            };
            NSDictionary *none = @{@"dance": @0, @"alt": @0, @"rap": @0, @"chill": @0};
            NSDictionary *all = @{@"dance": @2, @"alt": @2, @"rap": @2, @"chill": @1};
            // No copy on disk, then a broken one: nothing to play, and no crash.
            root = relaunched();
            if ([[c valueForKey:@"mixLibrary"] count] || !KindMixRowOK(root, 5, 54, none, nil)) return Fail(__LINE__);
            [@"{not json" writeToFile:cachePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            root = relaunched();
            if ([[c valueForKey:@"mixLibrary"] count] || !KindMixRowOK(root, 5, 54, none, nil)) return Fail(__LINE__);
            // A copy saved an hour ago: the same tiles as with the library in memory.
            NSData *saved = MixLibraryCacheData(fixtureLibrary, NSDate.date.timeIntervalSince1970 - 3600);
            if (![saved writeToFile:cachePath atomically:YES]) return Fail(__LINE__);
            root = relaunched();
            if ([[c valueForKey:@"mixLibrary"] count] != fixtureLibrary.count || !KindMixRowOK(root, 5, 54, all, nil) ||
                !FitsChildren(root))
                return Fail(__LINE__);
            // It is read once, not at every rebuild.
            [@"{not json" writeToFile:cachePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [c rebuildContent];
            root = p.contentViewController.view;
            if ([[c valueForKey:@"mixLibrary"] count] != fixtureLibrary.count || !KindMixRowOK(root, 5, 54, all, nil))
                return Fail(__LINE__);
            if (![saved writeToFile:cachePath atomically:YES]) return Fail(__LINE__);
            // A dislike given on this Mac is in its own record, not in the copy of the library:
            // after a relaunch that song is still out.
            NSDictionary *dance = nil;
            for (NSDictionary *t in fixtureLibrary)
                if ([MusicKindForGenre(t[@"genre"]) isEqual:@"dance"]) { dance = t; break; }
            if (!dance) return Fail(__LINE__);
            NSString *line = MixDislikeLine(dance[@"id"], SelectorTrackKey(dance[@"artist"], dance[@"title"]), dance[@"title"],
                                            dance[@"artist"], YES, NSDate.date);
            NSString *fbPath = [mixDir stringByAppendingPathComponent:@"feedback.jsonl"];
            if (!line.length || ![[line stringByAppendingString:@"\n"] writeToFile:fbPath atomically:YES encoding:NSUTF8StringEncoding error:nil])
                return Fail(__LINE__);
            root = relaunched();
            if (!KindMixRowOK(root, 5, 54, @{@"dance": @1, @"alt": @2, @"rap": @2, @"chill": @1}, nil)) return Fail(__LINE__);
            for (NSDictionary *t in [c valueForKey:@"mixLibrary"])
                if ([t[@"id"] isEqual:dance[@"id"]] && ![t[@"dislike"] boolValue]) return Fail(__LINE__);
            // Play by kind needs no popover and no Music either: it loads the copy itself.
            [c setValue:nil forKey:@"mixLibrary"];
            [c setValue:@NO forKey:@"mixLibraryCacheTried"];
            [c loadMixLibraryCacheIfNeeded];
            if ([[c valueForKey:@"mixLibrary"] count] != fixtureLibrary.count) return Fail(__LINE__);
            fprintf(stderr, "Library copy: tiles without Music, read once, a local dislike kept\n");
        } else if (musicState && strcmp(musicState, "dislike") == 0) {
            NSString *trackA = [fixtureMusic stringByAppendingPathComponent:@"dislike-a.m4a"];
            NSString *trackB = [fixtureMusic stringByAppendingPathComponent:@"dislike-b.m4a"];
            [@"silent a" writeToFile:trackA atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [@"silent b" writeToFile:trackB atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSString *dKey = @"faux pilot|wing one";
            NSString *fbPath = [fixtureHome stringByAppendingPathComponent:@"Library/Application Support/Glancebar/mix/feedback.jsonl"];
            [NSFileManager.defaultManager createDirectoryAtPath:[fbPath stringByDeletingLastPathComponent]
                                    withIntermediateDirectories:YES attributes:nil error:nil];
            [@"" writeToFile:fbPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [c setValue:@YES forKey:@"musicProbesEnabled"];
            [c setValue:@YES forKey:@"musicSilentQA"];
            [c setValue:@YES forKey:@"localMode"];
            [c setValue:@YES forKey:@"playbackKnown"];
            [c setValue:@YES forKey:@"playbackPlaying"];
            [c setValue:@"Wing One" forKey:@"localTitle"];
            [c setValue:@"Faux Pilot" forKey:@"localArtist"];
            [c setValue:@0 forKey:@"localIndex"];
            [c setValue:@[[NSURL fileURLWithPath:trackA], [NSURL fileURLWithPath:trackB]] forKey:@"localURLs"];
            [c setValue:@[
                @{@"file": trackA, @"artist": @"Faux Pilot", @"title": @"Wing One", @"key": dKey},
                @{@"file": trackB, @"artist": @"Faux Pilot", @"title": @"Wing Two", @"key": @"faux pilot|wing two"}
            ] forKey:@"stationTracks"];
            [c setValue:@YES forKey:@"localTagsReady"];
            [c rebuildContent];
            root = p.contentViewController.view;
            NSButton *thumbsdown = (NSButton *)FindIdentifier(root, @"popover.music.thumbsdown");
            NSButton *thumb = (NSButton *)FindIdentifier(root, @"popover.music.thumbsup");
            NSView *title = FindIdentifier(root, @"popover.music.title");
            if (!thumbsdown || !thumb || NSMaxX(thumbsdown.frame) > NSMinX(thumb.frame) + 0.5 ||
                NSMaxX(title.frame) > NSMinX(thumbsdown.frame) - 6 + 0.5)
                return Fail(__LINE__);
            [c musicThumbsDown:nil];
            NSString *fb = [NSString stringWithContentsOfFile:fbPath encoding:NSUTF8StringEncoding error:nil];
            if (![fb containsString:@"\"event\":\"dislike\""]) return Fail(__LINE__);
            NSArray *urls = [c valueForKey:@"localURLs"];
            if (urls.count != 1 || ![[urls[0] path] isEqual:trackB] ||
                [[c valueForKey:@"localIndex"] integerValue] != 0)
                return Fail(__LINE__);
            [c setValue:@[
                @{@"file": trackA, @"artist": @"Faux Pilot", @"title": @"Wing One", @"key": dKey},
                @{@"file": trackB, @"artist": @"Faux Pilot", @"title": @"Wing Two", @"key": @"faux pilot|wing two"}
            ] forKey:@"stationTracks"];
            [c setValue:@[[NSURL fileURLWithPath:trackA], [NSURL fileURLWithPath:trackB]] forKey:@"localURLs"];
            [c setValue:@0 forKey:@"localIndex"];
            [c setValue:@"Wing One" forKey:@"localTitle"];
            [c setValue:@YES forKey:@"localTagsReady"];
            [c playLocalIndex:0];
            [c rebuildContent];
            [c musicThumbsDown:nil];
            fb = [NSString stringWithContentsOfFile:fbPath encoding:NSUTF8StringEncoding error:nil];
            if (![fb containsString:@"\"event\":\"undislike\""]) return Fail(__LINE__);
        }
        if (!ActionableMenuImages([c moreMenu])) return Fail(__LINE__);
        // Toolbar tabs, built but not ordered front. Every tab keeps its identifier and a symbol.
        NSWindow *details = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 660, 520)
                                                        styleMask:(NSWindowStyleMaskTitled |
                                                                   NSWindowStyleMaskClosable |
                                                                   NSWindowStyleMaskResizable)
                                                          backing:NSBackingStoreBuffered defer:YES];
        details.releasedWhenClosed = NO;
        [c setValue:details forKey:@"detailsWindow"];
        [c rebuildDetails];
        NSTabViewController *tabs = (NSTabViewController *)details.contentViewController;
        if (![tabs isKindOfClass:NSTabViewController.class] ||
            tabs.tabStyle != NSTabViewControllerTabStyleToolbar || tabs.tabViewItems.count != 7)
            return Fail(__LINE__);
        [c rebuildDetails];   // in-place refresh must keep the symbols and the documents
        if (tabs.tabViewItems.count != 7) return Fail(__LINE__);
        NSSet *idents = [NSSet setWithArray:@[@"overview", @"storage", @"battery", @"system", @"thermal", @"activity", @"ai"]];
        for (NSTabViewItem *item in tabs.tabViewItems) {
            if (!item.image || ![item.identifier isKindOfClass:NSString.class] ||
                ![idents containsObject:item.identifier]) return Fail(__LINE__);
            if ([item.identifier isEqual:@"overview"]) {
                NSView *doc = [item.view isKindOfClass:NSScrollView.class]
                    ? ((NSScrollView *)item.view).documentView : item.view;
                if (!HasText(doc, @"OVERVIEW") || !HasTip(doc, @"Macintosh HD") ||
                    !FindIdentifier(doc, @"details.overview.row.storage") ||
                    !FindIdentifier(doc, @"details.overview.row.battery") ||
                    !FindIdentifier(doc, @"details.overview.row.system")) return Fail(__LINE__);
                // viewController forwards -view. A structural refresh assigns item.view and
                // must actually replace the document the tab shows.
                NSView *marker = [[NSView alloc] initWithFrame:item.view.frame];
                marker.accessibilityIdentifier = @"details.replace-probe";
                item.view = marker;
                if (item.view != marker && item.viewController.view != marker) return Fail(__LINE__);
                item.view = [c detailViewForIdentifier:@"overview"];
            }
        }
        NSTabViewItem *aiTab=nil,*batteryTab=nil;
        for(NSTabViewItem *item in tabs.tabViewItems){
            if([item.identifier isEqual:@"ai"])aiTab=item;
            if([item.identifier isEqual:@"battery"])batteryTab=item;
        }
        NSView *unselectedAI=aiTab.view;
        if(((NSScrollView *)unselectedAI).documentView) return Fail(__LINE__);
        [tabs.tabView selectTabViewItemWithIdentifier:@"battery"];
        if(![((NSScrollView *)batteryTab.view).documentView.accessibilityIdentifier isEqual:@"details.battery"] || aiTab.view!=unselectedAI)
            return Fail(__LINE__);
        [c rebuildDetails];
        if(aiTab.view!=unselectedAI) return Fail(__LINE__);
        [tabs.tabView selectTabViewItemWithIdentifier:@"overview"];
        [c stopPowerTick];
        if (getenv("GLANCEBAR_DUMP_TIPS")) {
            for (NSString *rid in @[@"popover.row.storage", @"popover.row.battery", @"popover.row.system",
                                    @"popover.row.ai.claude", @"popover.row.ai.codex", @"popover.row.ai.cursor"])
                printf("--- %s\n%s\n", rid.UTF8String, FindIdentifier(p.contentViewController.view, rid).accessibilityHelp.UTF8String);
            for (NSString *rid in @[@"popover.battery.symbol", @"popover.ai.claude.gauge"])
                printf("--- %s\n%s\n", rid.UTF8String, FindIdentifier(p.contentViewController.view, rid).accessibilityHelp.UTF8String);
        }
        // Cursor is an ordinary one-bar row showing Grok + Composer (Cursor's own models);
        // the API pool is on the tooltip and gets its own window row on the AI tab.
        AIUsage *cursor = usage.lastObject;
        NSArray *legacyWindows = cursor.limitWindows;
        cursor.limitWindows = CursorLimitWindows(@{
            @"billingCycleEnd": @(NSDate.date.timeIntervalSince1970 + 27*86400),
            @"planUsage": @{@"apiPercentUsed": @83, @"autoPercentUsed": @59}}, NSDate.date.timeIntervalSince1970);
        [c rebuildContent];
        root = p.contentViewController.view;
        if (CountGauges(root) != 7 || FirstScrollView(root) || !FitsChildren(root) ||
            root.bounds.size.height > 468 || !InstrumentRowsFit(root)) return Fail(__LINE__);   // +22 output line, +90 seed tiles (title row + artist row)
        NSArray *compactDocs = @[root, [c overviewDetailsView].documentView, [c aiDetailsView].documentView];
        NSArray *compactStems = @[@"popover.ai.cursor", @"details.overview.ai.cursor", @"details.ai.cursor"];
        for (NSUInteger i = 0; i < compactDocs.count; i++) {
            NSView *doc = compactDocs[i]; NSString *stem = compactStems[i];
            Gauge *bar = (Gauge *)FindIdentifier(doc, [stem stringByAppendingString:@".gauge"]);
            NSTextField *value = (NSTextField *)FindIdentifier(doc, [stem stringByAppendingString:@".value"]);
            NSTextField *datum = (NSTextField *)FindIdentifier(doc, [stem stringByAppendingString:@".datum"]);
            NSView *reference = FindIdentifier(doc, [[stem stringByReplacingOccurrencesOfString:@"cursor" withString:@"codex"] stringByAppendingString:@".gauge"]);
            // Cursor = Grok row; the API pool is its own plain row beneath (popover and Overview),
            // and a window row on the AI tab.
            Gauge *api = (Gauge *)FindIdentifier(doc, [stem stringByAppendingString:@".api.gauge"]);
            NSTextField *apiValue = (NSTextField *)FindIdentifier(doc, [stem stringByAppendingString:@".api.value"]);
            if (![bar isKindOfClass:Gauge.class] || fabs(bar.fraction - .41) > .001 || bar.innerFraction >= 0 ||
                ![value.stringValue isEqual:@"41%"] ||
                !SameColumn(bar, reference) || fabs(NSHeight(bar.frame) - NSHeight(reference.frame)) > .5 ||
                ![datum.stringValue hasPrefix:@"resets "] ||
                (i < 2 && (![api isKindOfClass:Gauge.class] || fabs(api.fraction - .17) > .001 ||
                           ![apiValue.stringValue isEqual:@"17%"] || !SameColumn(api, bar))) ||
                !HasText(doc, @"17%")) return Fail(__LINE__);
        }
        NSView *aiDoc = [c aiDetailsView].documentView;
        if (![((NSTextField *)FindIdentifier(aiDoc, @"details.ai.window.cursor.0.label")).stringValue isEqual:@"Grok"] ||
            ![((NSTextField *)FindIdentifier(aiDoc, @"details.ai.window.cursor.1.label")).stringValue isEqual:@"API"]) return Fail(__LINE__);
        if (argc > 1) {
            NSString *stem = [[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension];
            NSAppearanceName look = argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
            if (!RenderOffscreen(root, [stem stringByAppendingString:@"-cursor.png"], look) ||
                !RenderOffscreen([c aiDetailsView].documentView, [stem stringByAppendingString:@"-cursor-ai.png"], look)) return Fail(__LINE__);
        }
        // Starlink adds exactly one aligned instrument, only while detected.
        if (FindIdentifier(root, @"popover.row.starlink")) return Fail(__LINE__);
        NSDictionary *starlink = @{@"cycleStart": @(MeteredCycleStartInZone(NSDate.date, MeteredResetDay(@"starlink"), MeteredZone(@"starlink")).timeIntervalSince1970),
            @"downloadBytes": @10100000000ULL, @"uploadBytes": @2300000000ULL,
            @"bytesPerSecond": @1400000, @"onLink": @YES, @"link": @"starlink"};
        [c setValue:starlink forKey:@"metered"];
        [c rebuildContent]; root = p.contentViewController.view;
        for (NSString *part in @[@"symbol", @"name", @"gauge", @"value", @"datum"])
            if (CountIdentifier(root, [@"popover.starlink." stringByAppendingString:part]) != 1) return Fail(__LINE__);
        Gauge *starlinkGauge = (Gauge *)FindIdentifier(root, @"popover.starlink.gauge");
        NSView *starlinkRow = FindIdentifier(root, @"popover.row.starlink");
        NSView *systemRow = FindIdentifier(root, @"popover.row.system");
        if (![starlinkGauge isKindOfClass:Gauge.class] || fabs(starlinkGauge.fraction - 0.876) > 0.001 ||
            starlinkGauge.markerFraction != -1 ||
            !SameColumn(starlinkGauge, FindIdentifier(root, @"popover.battery.gauge")) ||
            !SameSize(starlinkGauge, FindIdentifier(root, @"popover.battery.gauge")) ||
            fabs(NSMinY(starlinkRow.frame) - NSMaxY(systemRow.frame)) > 0.5 ||
            !HasText(starlinkRow, @"88%") || !HasTip(starlinkRow, @"Mac 12.4 GB of 100 GB") ||
            !HasTip(starlinkRow, @"↓ 10.1 GB  ↑ 2.3 GB") || !HasTip(starlinkRow, @"now 1.4 MB/s") ||
            !FitsChildren(root) || !InstrumentRowsFit(root) || WordyTip(starlinkRow) ||
            [starlinkRow.accessibilityHelp componentsSeparatedByString:@"\n"].count != 3) return Fail(__LINE__);
        NSView *starlinkDetails = [c overviewDetailsView].documentView;
        if (!FindIdentifier(starlinkDetails, @"details.overview.starlink.gauge") ||
            !HasTip(starlinkDetails, @"Mac 12.4 GB of 100 GB") || !FitsChildren(starlinkDetails)) return Fail(__LINE__);
        if (argc > 1) {
            NSString *stem = [[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension];
            NSAppearanceName look = argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
            if (!RenderOffscreen(root, [stem stringByAppendingString:@"-starlink.png"], look) ||
                !RenderOffscreen(starlinkDetails, [stem stringByAppendingString:@"-starlink-overview.png"], look)) return Fail(__LINE__);
        }
        NSMutableDictionary *fast = [starlink mutableCopy];
        fast[@"recentBytesPerSecond"] = @(87.6e9 / (5 * 3600 + 20 * 60));
        [c setValue:fast forKey:@"metered"];
        [c rebuildContent]; root = p.contentViewController.view;
        NSTextField *lasts = (NSTextField *)FindIdentifier(root, @"popover.starlink.datum");
        NSView *fastRow = FindIdentifier(root, @"popover.row.starlink");
        NSView *fastDetails = [c overviewDetailsView].documentView;
        NSTextField *detailLasts = (NSTextField *)FindIdentifier(fastDetails, @"details.overview.starlink.datum");
        if (![lasts.stringValue isEqual:@"lasts 5:20"] || ![lasts.textColor isEqual:NSColor.systemYellowColor] ||
            ![lasts.stringValue isEqual:detailLasts.stringValue] || ![lasts.textColor isEqual:detailLasts.textColor] ||
            [fastRow.accessibilityHelp componentsSeparatedByString:@"\n"].count != 4 || !HasTip(fastRow, @"resets ") ||
            !FitsChildren(root) || !InstrumentRowsFit(root) || WordyTip(fastRow) || !FitsChildren(fastDetails)) return Fail(__LINE__);
        if (argc > 1) {
            NSString *stem = [[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension];
            NSAppearanceName look = argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
            if (!RenderOffscreen(root, [stem stringByAppendingString:@"-starlink-lasts.png"], look) ||
                !RenderOffscreen(fastDetails, [stem stringByAppendingString:@"-starlink-lasts-overview.png"], look)) return Fail(__LINE__);
        }
        // The account total (every device) leads; Mac bytes since the read keep it live.
        NSMutableDictionary *withAccount = [starlink mutableCopy];
        double nowEpoch = NSDate.date.timeIntervalSince1970;
        withAccount[@"account"] = @{@"usedGB": @70.4, @"cycleStart": @(nowEpoch - 86400), @"cycleEnd": @(nowEpoch + 86400 * 20),
            @"fetchedAt": @(nowEpoch - 240), @"macCycleStart": starlink[@"cycleStart"], @"macBytes": @12100000000ULL};
        [c setValue:withAccount forKey:@"metered"];
        [c rebuildContent]; root = p.contentViewController.view;
        NSView *accountRow = FindIdentifier(root, @"popover.row.starlink");
        Gauge *accountGauge = (Gauge *)FindIdentifier(root, @"popover.starlink.gauge");
        NSView *accountDetails = [c overviewDetailsView].documentView;
        if (fabs(accountGauge.fraction - 0.293) > 0.001 || !HasText(accountRow, @"29%") ||
            !HasTip(accountRow, @"Starlink 70.7 GB of 100 GB · read 4 min ago + Mac 0.3") ||
            !HasTip(accountRow, @"Mac ↓ 10.1 GB  ↑ 2.3 GB") || HasTip(accountRow, @"account:") ||
            [accountRow.accessibilityHelp componentsSeparatedByString:@"\n"].count != 3 ||
            ![accountGauge.metricLabel isEqual:@"Starlink data remaining"] ||
            !HasTip(accountDetails, @"Starlink 70.7 GB") || !FitsChildren(root) || !InstrumentRowsFit(root) ||
            WordyTip(accountRow) || !FitsChildren(accountDetails)) return Fail(__LINE__);
        if (argc > 1) {
            NSString *stem = [[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension];
            NSAppearanceName look = argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
            if (!RenderOffscreen(root, [stem stringByAppendingString:@"-starlink-account.png"], look)) return Fail(__LINE__);
        }
        // A failed read keeps the last figure and says why; no figure at all falls back to the Mac.
        NSMutableDictionary *stale = [withAccount mutableCopy];
        NSMutableDictionary *staleAccount = [withAccount[@"account"] mutableCopy];
        staleAccount[@"problem"] = @"sign in at starlink.com in Chrome";
        stale[@"account"] = staleAccount;
        [c setValue:stale forKey:@"metered"];
        [c rebuildContent]; root = p.contentViewController.view;
        if (!HasText(FindIdentifier(root, @"popover.row.starlink"), @"29%") ||
            !HasTip(FindIdentifier(root, @"popover.row.starlink"), @"account: sign in at starlink.com in Chrome")) return Fail(__LINE__);
        stale[@"account"] = @{@"problem": @"Keychain access refused"};
        [c setValue:stale forKey:@"metered"];
        [c rebuildContent]; root = p.contentViewController.view;
        if (!HasText(FindIdentifier(root, @"popover.row.starlink"), @"88%") ||
            !HasTip(FindIdentifier(root, @"popover.row.starlink"), @"Mac 12.4 GB of 100 GB") ||
            !HasTip(FindIdentifier(root, @"popover.row.starlink"), @"account: Keychain access refused")) return Fail(__LINE__);
        NSMutableDictionary *telstra = [starlink mutableCopy];
        telstra[@"link"] = @"telstra";
        telstra[@"cycleStart"] = @(MeteredCycleStart(NSDate.date, MeteredResetDay(@"telstra")).timeIntervalSince1970);
        [c setValue:telstra forKey:@"metered"];
        [c rebuildContent]; root = p.contentViewController.view;
        NSView *telstraRow = FindIdentifier(root, @"popover.row.telstra");
        Gauge *telstraGauge = (Gauge *)FindIdentifier(root, @"popover.telstra.gauge");
        NSView *telstraDetails = [c overviewDetailsView].documentView;
        if (!telstraRow || FindIdentifier(root, @"popover.row.starlink") || !HasText(telstraRow, @"Telstra") ||
            !HasText(telstraRow, @"93%") || !HasTip(telstraRow, @"Mac 12.4 GB of 180 GB") ||
            telstraGauge.markerFraction != -1 || !SameColumn(telstraGauge, FindIdentifier(root, @"popover.battery.gauge")) ||
            !FindIdentifier(telstraDetails, @"details.overview.telstra.gauge") ||
            FindIdentifier(telstraDetails, @"details.overview.starlink.gauge") ||
            !FitsChildren(root) || !InstrumentRowsFit(root) || !FitsChildren(telstraDetails) || WordyTip(telstraRow)) return Fail(__LINE__);
        if (argc > 1) {
            NSString *stem = [[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension];
            NSAppearanceName look = argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
            if (!RenderOffscreen(root, [stem stringByAppendingString:@"-telstra.png"], look) ||
                !RenderOffscreen(telstraDetails, [stem stringByAppendingString:@"-telstra-overview.png"], look)) return Fail(__LINE__);
        }
        [c setValue:@{@"onLink": @NO} forKey:@"metered"];
        [c rebuildContent]; root = p.contentViewController.view;
        if (FindIdentifier(root, @"popover.row.starlink") || FindIdentifier(root, @"popover.row.telstra") ||
            FindIdentifier([c overviewDetailsView].documentView, @"details.overview.telstra.gauge") ||
            FindIdentifier([c overviewDetailsView].documentView, @"details.overview.starlink.gauge")) return Fail(__LINE__);

        if (argc > 1) {
            NSString *stem = [[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension];
            if (!RenderOffscreen(root, [stem stringByAppendingString:@"-metered-none.png"],
                                 argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)) return Fail(__LINE__);
        }

        // Every battery state renders without cut-off text: charging fast, held at the limit,
        // plugged but draining (the 2026-10-08 "−7.9 W plug…" bug), no power in, and on battery.
        {
            struct { BOOL ac, charging; int pct; long amps, in, load; } states[] = {
                {YES, YES, 42, 2400, 60000, 9000},   // fast charge, time to target
                {YES, NO, 80, 0, 9000, 9000},        // held at 80%
                {YES, NO, 78, -660, 4000, 11900},    // plugged, battery still carrying load
                {YES, NO, 78, -900, 0, 11000},       // charger recognised, nothing arriving
                {NO, NO, 63, -1100, 0, 13200},       // on battery
                {NO, NO, 12, -2400, 0, 28800},       // low and heavy
            };
            for (size_t i = 0; i < sizeof states / sizeof states[0]; i++) {
                BatteryState sb = b;
                sb.acConnected = states[i].ac; sb.isCharging = states[i].charging; sb.percent = states[i].pct;
                sb.minutesToEmpty = states[i].ac ? -1 : 120;
                sb.minutesToFull = states[i].charging ? 95 : -1;
                sb.amperage_mA = states[i].amps; sb.systemPowerIn_mW = states[i].in; sb.systemLoad_mW = states[i].load;
                [c setValue:[NSValue valueWithBytes:&sb objCType:@encode(BatteryState)] forKey:@"bat"];
                PrimeBatteryForecast(c, sb, YES);
                [c rebuildContent];
                NSView *pop = p.contentViewController.view;
                BatteryForecastView *fv = (BatteryForecastView *)FindIdentifier(pop, @"popover.battery.forecast");
                // Times sit on the winning side: a charger short of the load forecasts 20%/empty.
                BOOL filling = sb.acConnected && !ChargerFallsShort(sb);
                if (!ForecastFits(fv) || fv.forecast.thresholdPercent != (filling ? 80 : 20) ||
                    fv.forecast.endpointPercent != (filling ? 100 : 0)) return Fail(__LINE__);
                if ((FindIdentifier(pop, @"popover.row.charger") != nil) != ChargerFallsShort(sb)) return Fail(__LINE__);
                if (!sb.acConnected && !([fv.endpointText hasSuffix:@"m"] || [fv.endpointText hasSuffix:@"h"])) return Fail(__LINE__);
                if (sb.percent <= 20 && !sb.acConnected && fv.thresholdText.length) return Fail(__LINE__);
                if (sb.acConnected && sb.isCharging && sb.percent<80 &&
                    (fv.forecast.endpointTime<=0 || !fv.forecast.hypotheticalFull ||
                     ![fv.accessibilityHelp containsString:@"assumes the 80% limit is cancelled"])) return Fail(__LINE__);
                if (sb.acConnected && sb.percent>=80 && (fv.thresholdText.length || fv.endpointText.length)) return Fail(__LINE__);
                NSTextField *bd = (NSTextField *)FindIdentifier(pop, @"popover.battery.datum");
                TrendArrow *ta = (TrendArrow *)FindIdentifier(pop, @"popover.battery.trend");
                BOOL moving = fabs(BatteryWatts(sb)) >= 0.3;
                if (!FitsChildren(pop) || ![bd.stringValue hasSuffix:@" W"] || ![ta isKindOfClass:TrendArrow.class] ||
                    (moving && sb.percent > 0 && ta.hidden && !(BatteryWatts(sb) > 0 && sb.percent >= 80)) ||
                    // Charging shows the green in-vector; draining shows the orange draw-vector.
                    (moving && !ta.hidden && (BatteryWatts(sb) > 0 ? !(ta.to > ta.from)
                                                                  : !(isfinite(ta.drawTo) && ta.drawTo < ta.from)))) {
                    fprintf(stderr, "battery state %zu: \"%s\"\n", i, bd.stringValue.UTF8String);
                    return Fail(__LINE__);
                }
                if (argc > 1 &&
                    !RenderOffscreen(pop, [[[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension]
                        stringByAppendingFormat:@"-battery%zu.png", i], argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua))
                    return Fail(__LINE__);
            }
            [c setValue:[NSValue valueWithBytes:&b objCType:@encode(BatteryState)] forKey:@"bat"];
        PrimeBatteryForecast(c, b, YES);
            [c rebuildContent];
            for (NSString *tab in @[@"overview", @"storage", @"battery", @"system", @"thermal", @"activity", @"ai"]) {
                NSView *doc = ((NSScrollView *)[c detailViewForIdentifier:tab]).documentView;
                if (!FitsChildren(doc)) { fprintf(stderr, "details tab %s\n", tab.UTF8String); return Fail(__LINE__); }
            }
        }
        {
            struct { BOOL ac, charging, full; int pct; long amps, empty, fullMinutes; const char *name; } cases[] = {
                {NO,NO,NO,63,-1100,120,-1,"discharge"},
                {YES,YES,NO,42,2400,-1,90,"charge"},
                {YES,YES,NO,95,200,-1,70,"taper"},
                {YES,NO,NO,80,0,-1,70,"paused"},
                {YES,NO,YES,100,0,-1,70,"full"},
                {NO,NO,NO,63,-1100,-1,-1,"startup"},
                {YES,YES,NO,65,3200,-1,64,"limit-charge"},
                {YES,NO,NO,80,0,-1,55,"limit-held"},
            };
            [c setValue:@"full" forKey:@"chargeMode"];
            [c setValue:NSDate.date forKey:@"chargeModeAt"];
            for (size_t i=0;i<sizeof cases / sizeof cases[0];i++) {
                BOOL limit = i>=6;
                [c setValue:limit ? @"limit80" : @"full" forKey:@"chargeMode"];
                BatteryState sb=b; sb.acConnected=cases[i].ac; sb.isCharging=cases[i].charging;
                sb.fullyCharged=cases[i].full; sb.percent=cases[i].pct; sb.amperage_mA=cases[i].amps;
                sb.minutesToEmpty=cases[i].empty; sb.minutesToFull=cases[i].fullMinutes;
                [c setValue:[NSValue valueWithBytes:&sb objCType:@encode(BatteryState)] forKey:@"bat"];
                if (i==5) [c setValue:[BatteryForecastTracker new] forKey:@"batteryForecastTracker"];
                else PrimeBatteryForecast(c,sb,limit);
                [c rebuildContent];
                NSView *pop=p.contentViewController.view;
                BatteryForecastView *fv=(BatteryForecastView *)FindIdentifier(pop,@"popover.battery.forecast");
                if (!ForecastFits(fv) || !FitsChildren(pop)) return Fail(__LINE__);
                if (i==1 && (![fv.thresholdText isEqual:@"45m"] || ![fv.endpointText isEqual:@"1.5h"])) return Fail(__LINE__);
                if (i==2 && (fv.thresholdText.length || ![fv.endpointText hasSuffix:@"h"])) return Fail(__LINE__);
                if (i==3 && (fv.forecast.endpointTime || fv.forecast.thresholdTime)) return Fail(__LINE__);
                if (i==4 && (fv.thresholdText.length || fv.endpointText.length)) return Fail(__LINE__);
                if (i==5 && (![fv.thresholdText isEqual:@"—"] || ![fv.endpointText isEqual:@"—"])) return Fail(__LINE__);
                if (i==6 && (fv.forecast.thresholdTime<=0 || fv.forecast.endpointTime<=0 || !fv.forecast.hypotheticalFull)) return Fail(__LINE__);
                if (i==7 && (!fv.forecast.hideLabels || fv.thresholdText.length || fv.endpointText.length)) return Fail(__LINE__);
                NSArray *surfaces=@[pop, [c overviewDetailsView].documentView, [c batteryDetailsView].documentView];
                NSArray *names=@[@"popover", @"overview", @"details"];
                NSArray *idents=@[@"popover.battery.forecast", @"details.overview.battery.forecast", @"details.battery.charge.forecast"];
                for (NSUInteger j=0;j<surfaces.count;j++) {
                    BatteryForecastView *other=(BatteryForecastView *)FindIdentifier(surfaces[j],idents[j]);
                    if (!ForecastFits(other) || !FitsChildren(surfaces[j])) {
                        fprintf(stderr,"forecast case=%zu surface=%s bounds=%s a=%s b=%s attrs=%s\n",i,[names[j] UTF8String],
                            NSStringFromRect(other.bounds).UTF8String,NSStringFromRect([other labelRect:YES]).UTF8String,
                            NSStringFromRect([other labelRect:NO]).UTF8String,[[other labelAttributes] description].UTF8String);
                        return Fail(__LINE__);
                    }
                    if (i>=6 && (![other.thresholdText isEqual:fv.thresholdText] || ![other.endpointText isEqual:fv.endpointText])) return Fail(__LINE__);
                    if (argc>1) {
                        NSString *path=[[[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension]
                            stringByAppendingFormat:@"-forecast-%s-%@.png",cases[i].name,names[j]];
                        if (!RenderOffscreen(surfaces[j],path,argc>2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)) return Fail(__LINE__);
                    }
                }
            }
            [c setValue:@"limit80" forKey:@"chargeMode"];
            [c setValue:[NSValue valueWithBytes:&b objCType:@encode(BatteryState)] forKey:@"bat"];
            PrimeBatteryForecast(c,b,YES);
        }

        {
            BatteryForecastView *probe=[[BatteryForecastView alloc] initWithFrame:NSZeroRect];
            NSArray *labels=@[@"<5m",@"5m",@"45m",@"55m",@"1h",@"1.5h",@"9.9h",@"10h",@"24h",@"—"];
            for (NSNumber *gaugeWidth in @[@94,@102,@222]) {
                probe.frame=NSMakeRect(0,0,gaugeWidth.doubleValue+2*kBatteryForecastSideRoom,30);
                for (int endpoint=0;endpoint<=100;endpoint+=100) {
                    probe.forecast=(BatteryForecast){.thresholdPercent=endpoint ? 80 : 20,.endpointPercent=endpoint};
                    for (NSString *text in labels) for (NSString *other in labels) {
                        probe.thresholdText=text; probe.endpointText=other;
                        if (!ForecastFits(probe)) return Fail(__LINE__);
                    }
                }
            }
            fprintf(stderr,"Forecast geometry: 600 text/width/direction combinations passed\n");
        }

        // On battery: Burn appears only for actionable quit gains; the Battery
        // tab lists each app's watts and Wh since unplug, the screen + system rest, and the total.
        {
            id savedAmpHistory = [c valueForKey:@"ampHistory"];
            BatteryState onBattery = b;
            onBattery.acConnected = NO; onBattery.isCharging = NO; onBattery.amperage_mA = -780;
            onBattery.systemPowerIn_mW = 0; onBattery.systemLoad_mW = 9400; onBattery.adapterWatts = 0;
            [c setValue:[NSValue valueWithBytes:&onBattery objCType:@encode(BatteryState)] forKey:@"bat"];
            [c setValue:[NSMutableArray arrayWithObject:@(onBattery.amperage_mA)] forKey:@"ampHistory"];
            [c setValue:@[@{@"name": @"Google Chrome", @"watts": @2.1, @"wh": @1.4},
                          @{@"name": @"node", @"watts": @1.3, @"wh": @0.9},
                          @{@"name": @"Codex", @"watts": @0.6, @"wh": @0.4},
                          @{@"name": @"Mail", @"watts": @0.2, @"wh": @0.1}] forKey:@"burnRows"];
            [c setValue:[NSDate dateWithTimeIntervalSinceNow:-102 * 60] forKey:@"energyBaselineAt"];
            [c setValue:@YES forKey:@"energyBaselineAtUnplug"];
            [c setValue:@(BatteryWattHours(onBattery.rawCurrent_mAh, onBattery.voltage_mV) + 6.1) forKey:@"energyBaselineWh"];
            [c rebuildContent];
            NSView *pop = p.contentViewController.view;
            NSTextField *burnValue = (NSTextField *)FindIdentifier(pop, @"popover.burn.value");
            NSTextField *burnDatum = (NSTextField *)FindIdentifier(pop, @"popover.burn.datum");
            Gauge *burnBar = (Gauge *)FindIdentifier(pop, @"popover.burn.gauge");
            // Quitting Chrome stretches the Battery row's time to 20% by T * A / (D - A).
            double gain = MinutesTo20(onBattery, onBattery.amperage_mA) * 2.1 / (9.4 - 2.1);
            BOOL expected = gain >= 30;
            if ((FindIdentifier(pop, @"popover.row.burn") != nil) != expected) return Fail(__LINE__);
            if (expected && (![burnValue.stringValue isEqual:@"2.1 W"] ||
                ![burnDatum.stringValue isEqual:[@"quit +" stringByAppendingString:FmtDuration((int)lround(gain))]] ||
                ![burnBar isKindOfClass:Gauge.class] || fabs(burnBar.fraction - 2.1 / 9.4) > 1e-6 ||
                !SameColumn(burnBar, FindIdentifier(pop, @"popover.battery.gauge")) ||
                !HasTip(pop, @"Since unplug: 6.1 Wh over 1:42") ||
                !HasTip(pop, @"Chrome 2.1 W · 1.4 Wh") || !HasTip(pop, @"Screen + system 5.2 W") ||
                ![((NSTextField *)FindIdentifier(pop, @"popover.burn.name")).stringValue isEqual:@"Chrome"] ||
                [burnDatum.stringValue sizeWithAttributes:@{NSFontAttributeName: burnDatum.font}].width > NSWidth(burnDatum.bounds))) return Fail(__LINE__);
            if (!FitsChildren(pop) || FirstScrollView(pop)) return Fail(__LINE__);
            NSView *batteryDoc = [c batteryDetailsView].documentView;
            NSTextField *since = (NSTextField *)FindIdentifier(batteryDoc, @"details.battery.burn.since.value");
            NSTextField *chromeWh = (NSTextField *)FindIdentifier(batteryDoc, @"details.battery.burn.0.datum");
            NSTextField *rest = (NSTextField *)FindIdentifier(batteryDoc, @"details.battery.burn.system.value");
            if (![since.stringValue isEqual:@"6.1 Wh"] || ![chromeWh.stringValue isEqual:@"1.4 Wh"] ||
                ![rest.stringValue isEqual:@"5.2 W"] || FindIdentifier(batteryDoc, @"details.battery.bar.energy.0")) return Fail(__LINE__);
            if (argc > 1) {
                NSString *stem = [[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension];
                NSAppearanceName look = argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
                if (!RenderOffscreen(pop, [stem stringByAppendingString:@"-burn.png"], look) ||
                    !RenderOffscreen(batteryDoc, [stem stringByAppendingString:@"-burn-details.png"], look)) return Fail(__LINE__);
            }
            onBattery.systemLoad_mW = 21000; onBattery.amperage_mA = -1750;
            [c setValue:[NSValue valueWithBytes:&onBattery objCType:@encode(BatteryState)] forKey:@"bat"];
            [c setValue:[NSMutableArray arrayWithObject:@(onBattery.amperage_mA)] forKey:@"ampHistory"];
            [c setValue:@[@{@"name": @"node", @"watts": @14, @"wh": @2}] forKey:@"burnRows"];
            [c rebuildContent];
            pop = p.contentViewController.view;
            burnValue = (NSTextField *)FindIdentifier(pop, @"popover.burn.value");
            burnDatum = (NSTextField *)FindIdentifier(pop, @"popover.burn.datum");
            burnBar = (Gauge *)FindIdentifier(pop, @"popover.burn.gauge");
            if (!FindIdentifier(pop, @"popover.row.burn") || ![burnValue.stringValue isEqual:@"14 W"] ||
                ![burnValue.textColor isEqual:NSColor.systemRedColor] || ![burnDatum.stringValue hasPrefix:@"quit +"] ||
                fabs(burnBar.fraction - 14.0 / 21) > 1e-6 ||
                !SameColumn(burnBar, FindIdentifier(pop, @"popover.battery.gauge")) ||
                [burnDatum.stringValue sizeWithAttributes:@{NSFontAttributeName: burnDatum.font}].width > NSWidth(burnDatum.bounds) ||
                !FitsChildren(pop) || FirstScrollView(pop)) return Fail(__LINE__);
            if (argc > 1) {
                NSString *stem = [[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension];
                NSAppearanceName look = argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
                if (!RenderOffscreen(pop, [stem stringByAppendingString:@"-burn-runaway.png"], look)) return Fail(__LINE__);
            }
            onBattery.systemLoad_mW = 4100; onBattery.amperage_mA = -342;
            [c setValue:[NSValue valueWithBytes:&onBattery objCType:@encode(BatteryState)] forKey:@"bat"];
            [c setValue:[NSMutableArray arrayWithObject:@(onBattery.amperage_mA)] forKey:@"ampHistory"];
            [c setValue:@[@{@"name": @"Finder", @"watts": @0.2, @"wh": @0.1}] forKey:@"burnRows"];
            [c rebuildContent];
            if (FindIdentifier(p.contentViewController.view, @"popover.row.burn")) return Fail(__LINE__);
            {
                // A plane's USB port: 6 W in, the Mac using 16 W, IDrive's root daemon estimated.
                BatteryState shortCharger = onBattery;
                shortCharger.acConnected = YES; shortCharger.percent = 68; shortCharger.minutesToEmpty = -1;
                shortCharger.systemPowerIn_mW = 6000; shortCharger.systemLoad_mW = 16000;
                shortCharger.amperage_mA = -(long)lround(10.0e6 / shortCharger.voltage_mV);
                [c setValue:[NSValue valueWithBytes:&shortCharger objCType:@encode(BatteryState)] forKey:@"bat"];
                for (NSNumber *appW in @[@9, @11]) {
                    [c setValue:@[@{@"name": @"IDrive", @"watts": appW, @"wh": @0, @"estimated": @YES}] forKey:@"burnRows"];
                    [c rebuildContent];
                    pop = p.contentViewController.view;
                    burnValue = (NSTextField *)FindIdentifier(pop, @"popover.burn.value");
                    burnDatum = (NSTextField *)FindIdentifier(pop, @"popover.burn.datum");
                    BOOL charges = appW.doubleValue >= 10;
                    if (!FindIdentifier(pop, @"popover.row.burn") || !FindIdentifier(pop, @"popover.row.charger") ||
                        ![burnValue.stringValue hasSuffix:@" W"] ||
                        (charges ? ![burnDatum.stringValue isEqual:@"quit \u2192 charges"] : ![burnDatum.stringValue hasPrefix:@"quit +"]) ||
                        [burnDatum.stringValue sizeWithAttributes:@{NSFontAttributeName: burnDatum.font}].width > NSWidth(burnDatum.bounds) ||
                        !FitsChildren(pop)) {
                        fprintf(stderr, "short charger burn: \"%s\" \"%s\" row %d charger %d width %.1f/%.1f fits %d\n", burnValue.stringValue.UTF8String, burnDatum.stringValue.UTF8String,
                            FindIdentifier(pop, @"popover.row.burn") != nil, FindIdentifier(pop, @"popover.row.charger") != nil,
                            [burnDatum.stringValue sizeWithAttributes:@{NSFontAttributeName: burnDatum.font}].width, NSWidth(burnDatum.bounds), FitsChildren(pop));
                        return Fail(__LINE__);
                    }
                    if (argc > 1) {
                        NSString *stem = [[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension];
                        NSAppearanceName look = argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
                        if (!RenderOffscreen(pop, [stem stringByAppendingFormat:@"-burn-short-%@.png", appW], look)) return Fail(__LINE__);
                    }
                }
            }
            // Keep an actionable sample on AC to prove power source alone hides it.
            [c setValue:@[@{@"name": @"node", @"watts": @14, @"wh": @2}] forKey:@"burnRows"];
            [c setValue:nil forKey:@"energyBaselineAt"];
            [c setValue:savedAmpHistory forKey:@"ampHistory"];
            [c setValue:[NSValue valueWithBytes:&b objCType:@encode(BatteryState)] forKey:@"bat"];
        PrimeBatteryForecast(c, b, YES);
            [c rebuildContent];
            if (FindIdentifier(p.contentViewController.view, @"popover.row.burn")) return Fail(__LINE__);   // plugged in: gone
        }
        cursor.limitStale = YES; cursor.limitUpdatedAt = [NSDate dateWithTimeIntervalSinceNow:-7200];
        cursor.limitRefreshError = @"Signed out — sign in to Cursor";
        [c rebuildContent];
        for (NSString *scope in @[@"popover.ai", @"details.ai", @"details.overview.ai"]) {
            NSView *doc = [scope isEqual:@"popover.ai"] ? p.contentViewController.view
                : [scope isEqual:@"details.ai"] ? [c aiDetailsView].documentView : [c overviewDetailsView].documentView;
            NSTextField *datum = (NSTextField *)FindIdentifier(doc, [scope stringByAppendingString:@".cursor.datum"]);
            NSTextField *grok = (NSTextField *)FindIdentifier(doc, [scope stringByAppendingString:@".cursor.value"]);
            if (![datum.stringValue isEqual:@"signed out"] || ![grok.stringValue isEqual:@"41%"] ||
                FindIdentifier(doc, [scope stringByAppendingString:@".cursor.status"]) || !FitsChildren(doc)) return Fail(__LINE__);
        }
        if (argc > 1) {
            NSString *path = [[[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension] stringByAppendingString:@"-signed-out.png"];
            if (!RenderOffscreen(p.contentViewController.view, path, argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)) return Fail(__LINE__);
        }
        cursor.limitRefreshError = nil;
        [c rebuildContent];
        NSTextField *staleDatum = (NSTextField *)FindIdentifier(p.contentViewController.view, @"popover.ai.cursor.datum");
        if (![staleDatum.stringValue hasPrefix:@"stale"]) return Fail(__LINE__);
        cursor.limitStale = NO; cursor.limitUpdatedAt = NSDate.date;
        NSArray *bothPools = cursor.limitWindows;
        // 100% fits the ordinary value column.
        cursor.limitWindows = CursorLimitWindows(@{@"planUsage": @{@"apiPercentUsed": @0, @"autoPercentUsed": @0}}, NSDate.date.timeIntervalSince1970);
        [c rebuildContent];
        NSTextField *full = (NSTextField *)FindIdentifier(p.contentViewController.view, @"popover.ai.cursor.value");
        if (![full.stringValue isEqual:@"100%"] || !FitsChildren(p.contentViewController.view)) return Fail(__LINE__);
        // One pool missing: the bar shows what is reported (Grok, else API) and never invents the other.
        for (NSUInteger missing = 0; missing < 2; missing++) {
            cursor.limitWindows = @[bothPools[missing]];
            [c rebuildContent];
            NSTextField *shown = (NSTextField *)FindIdentifier(p.contentViewController.view, @"popover.ai.cursor.value");
            if (![shown.stringValue isEqual:(missing == 0 ? @"17%" : @"41%")] ||
                FindIdentifier(p.contentViewController.view, @"popover.row.ai.cursor.api")) return Fail(__LINE__);
        }
        cursor.limitWindows = bothPools;
        [c rebuildContent];
        root = p.contentViewController.view;
        const char *detailsPrefix = getenv("GLANCEBAR_RENDER_DETAILS");
        if (detailsPrefix && detailsPrefix[0]) {
            NSAppearanceName appearance = argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
            for (NSString *tab in @[@"overview", @"storage", @"battery", @"system", @"thermal", @"activity", @"ai"]) {
                NSScrollView *scroll = [c detailViewForIdentifier:tab];
                NSView *doc = [scroll isKindOfClass:NSScrollView.class] ? scroll.documentView : scroll;
                NSString *path = [NSString stringWithFormat:@"%s-%@.png", detailsPrefix, tab];
                if (!RenderOffscreen(doc, path, appearance)) return Fail(__LINE__);
            }
        }
        [c setValue:nil forKey:@"detailsWindow"];
        if (argc > 1 && !gStationRender) {
            root.appearance = [NSAppearance appearanceNamed:(argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)];
            NSBitmapImageRep *rep = [root bitmapImageRepForCachingDisplayInRect:root.bounds];
            [root cacheDisplayInRect:root.bounds toBitmapImageRep:rep];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES];
        }
        cursor.limitWindows = legacyWindows;
        // Rebuild in place must keep navigation reachable and not accumulate rows.
        [c rebuildContent];
        if (CountGauges(p.contentViewController.view) != 6) return Fail(__LINE__);
        AIUsage *codex = usage[1]; codex.billingNote = @"Requests now bill to credits · balance 20";
        [c rebuildContent];
        if (!HasTip(p.contentViewController.view, @"Using credits")) return Fail(__LINE__);
        // Missing and stale provider data must stay compact without faking a healthy bar.
        AIUsage *missing = usage.lastObject; missing.limitStatusAvailable = NO;
        missing.remainingFraction = -1; missing.resetAt = nil; missing.statusReason = @"Account unavailable";
        [c rebuildContent];
        if (CountGauges(p.contentViewController.view) != 5 ||
            !HasTip(p.contentViewController.view, @"Account unavailable") ||
            !HasText(p.contentViewController.view, @"unavailable")) return Fail(__LINE__);
        meter = FindClaudeMeter(p.contentViewController.view);
        AIUsage *claude = usage[0];
        claude.limitWindows = @[@{@"remainingFraction":@0.82, @"window":@"weekly Fable"}];
        [c rebuildContent];
        QuotaPairGauge *updated = FindClaudeMeter(p.contentViewController.view);
        // Only a Fable window reported: no all-models weekly figure, so no fill at all (never Fable's).
        if (updated != meter || updated.firstFraction >= 0 || updated.secondFraction != -1) return Fail(__LINE__);
        claude.limitWindows = @[];
        [c rebuildContent];
        if (HasText(p.contentViewController.view, @"Fable") || CountGauges(p.contentViewController.view) != 5 ||
            !FitsChildren(p.contentViewController.view)) return Fail(__LINE__);
        claude.limitWindows = @[@{@"remainingFraction":@0.82, @"window":@"weekly Fable"}];
        claude.limitWindows = @[@{@"remainingFraction":@1, @"window":@"weekly Fable"},
                               @{@"remainingFraction":@1, @"window":@"weekly Opus"}];
        [c rebuildContent];
        if (!HasText(p.contentViewController.view,@"100%") || HasText(p.contentViewController.view,@"/100") ||
            !FitsChildren(p.contentViewController.view)) return Fail(__LINE__);
        claude.overageActive = YES;
        [c rebuildContent];
        if (HasText(p.contentViewController.view, @"Fable") || !FitsChildren(p.contentViewController.view)) return Fail(__LINE__);
        if (getenv("GLANCEBAR_RENDER_LIVE_BATTERY") && argc > 1) {
            BatteryState live=ReadBattery();
            [c setValue:[NSValue valueWithBytes:&live objCType:@encode(BatteryState)] forKey:@"bat"];
            [c setValue:[BatteryForecastTracker new] forKey:@"batteryForecastTracker"];
            [c rebuildContent];
            NSString *path=[[[NSString stringWithUTF8String:argv[1]] stringByDeletingPathExtension] stringByAppendingString:@"-live-battery.png"];
            if (!RenderOffscreen(p.contentViewController.view,path,argc>2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)) return Fail(__LINE__);
            BatteryForecast forecast=[c batteryForecast];
            fprintf(stderr,"Live battery: %d%% AC=%d charging=%d empty=%ld full=%ld telemetryAge=%.0fs; 20/80=%s 0/100=%s\n",
                live.percent,live.acConnected,live.isCharging,live.minutesToEmpty,live.minutesToFull,
                NSDate.date.timeIntervalSince1970-live.telemetryTimestamp,
                BatteryForecastClock(forecast.thresholdTime,nil).UTF8String,BatteryForecastClock(forecast.endpointTime,nil).UTF8String);
        }
        return 0;
    }
}
