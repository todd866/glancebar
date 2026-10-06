// Render the real popover offscreen; never launch the app, status item, or samplers.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Watomic-property-with-user-defined-accessor"
#pragma clang diagnostic ignored "-Wunused-parameter"
#define main GlancebarApplicationMain
#import "../Sources/main.m"
#undef main
#pragma clang diagnostic pop

static NSUInteger CountGauges(NSView *view) {
    NSUInteger count = ([view isKindOfClass:Gauge.class] || [view isKindOfClass:ClaudeGauge.class]) ? 1 : 0;
    for (NSView *child in view.subviews) count += CountGauges(child);
    return count;
}
static ClaudeGauge *FindClaudeMeter(NSView *view) {
    if ([view isKindOfClass:ClaudeGauge.class]) return (ClaudeGauge *)view;
    for (NSView *child in view.subviews) { ClaudeGauge *m = FindClaudeMeter(child); if (m) return m; }
    return nil;
}
static BOOL HasText(NSView *view, NSString *text) {
    if ([view isKindOfClass:NSTextField.class] && [((NSTextField *)view).stringValue containsString:text]) return YES;
    for (NSView *child in view.subviews) if (HasText(child, text)) return YES;
    return NO;
}
static BOOL HasTip(NSView *view, NSString *text) {
    if ([view.toolTip containsString:text]) return YES;
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
        output.superview != row || titleField.superview != row || subtitleField.superview != row) return NO;
    if (prev.enabled != transportOn || next.enabled != transportOn) return NO;
    return FindIdentifier(root, @"popover.sound.chevron") == nil &&
           FindIdentifier(root, @"popover.sound.name") == nil;
}
static BOOL FitsChildren(NSView *view) {
    for (NSView *child in view.subviews) {
        if (!NSContainsRect(view.bounds, child.frame) || !FitsChildren(child)) return NO;
        if ([child isKindOfClass:NSTextField.class] && [child.accessibilityIdentifier hasPrefix:@"popover.claude."]) {
            NSTextField *field = (NSTextField *)child;
            if ([field.stringValue sizeWithAttributes:@{NSFontAttributeName:field.font}].width > field.bounds.size.width - 4) return NO;
        }
    }
    return YES;
}
static NSColor *MeterPixel(ClaudeGauge *meter, CGFloat x, CGFloat y) {
    meter.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    NSBitmapImageRep *rep = [meter bitmapImageRepForCachingDisplayInRect:meter.bounds];
    [meter cacheDisplayInRect:meter.bounds toBitmapImageRep:rep];
    return [[rep colorAtX:(NSInteger)(x*rep.pixelsWide/meter.bounds.size.width)
                       y:(NSInteger)(y*rep.pixelsHigh/meter.bounds.size.height)] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
}
static BOOL Red(NSColor *c) { return c && c.redComponent > c.greenComponent + 0.2; }
static BOOL Green(NSColor *c) { return c && c.greenComponent > c.redComponent + 0.2; }
static int Fail(int line) { fprintf(stderr, "Popover check failed at line %d\n", line); return 1; }
int main(int argc, const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        ClaudeGauge *probe = [[ClaudeGauge alloc] initWithFrame:NSMakeRect(0,0,100,8)];
        probe.fable = 0.06; probe.opus = 0.8;
        if (!Red(MeterPixel(probe,3,1)) || !Green(MeterPixel(probe,40,1)) ||
            !Green(MeterPixel(probe,40,6))) return Fail(__LINE__);
        probe.fable = 0.8; probe.opus = 0.06;
        if (!Green(MeterPixel(probe,40,4)) || !Red(MeterPixel(probe,3,4))) return Fail(__LINE__);
        probe.fable = 0;
        if (!Red(MeterPixel(probe,3,4))) return Fail(__LINE__);
        // A full reset and near-ties use lanes, with each endpoint independently visible.
        probe.fable = probe.opus = 1;
        if (!Green(MeterPixel(probe,90,1)) || !Green(MeterPixel(probe,90,6))) return Fail(__LINE__);
        if (!ClaudeQuotasClose(.30,.33) || ClaudeQuotasClose(.30,.34) || ClaudeQuotasClose(-1,0)) return Fail(__LINE__);
        probe.fable = .30; probe.opus = .32;
        if (!Red(MeterPixel(probe,20,1)) || !Red(MeterPixel(probe,20,6))) return Fail(__LINE__);
        // Two healthy quotas: solid green to the shorter (50%), a lighter green to 71%.
        probe.fable = .50; probe.opus = .71;
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
        probe.fable = .30; probe.opus = .60;
        if (!Green(MeterPixel(probe,45,1)) || !Green(MeterPixel(probe,45,6))) return Fail(__LINE__);
        NSColor *lowOpus = MeterPixel(probe,20,4);
        __block NSColor *amber;
        [probe.appearance performAsCurrentDrawingAppearance:^{
            amber = [NSColor.systemOrangeColor colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        }];
        if (fabs(lowOpus.redComponent-amber.redComponent)>0.03 ||
            fabs(lowOpus.greenComponent-amber.greenComponent)>0.03 ||
            fabs(lowOpus.blueComponent-amber.blueComponent)>0.03) return Fail(__LINE__);
        Controller *c = [Controller new];
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
            .memTotal=34359738368, .memUsed=17179869184, .memAvailable=17179869184, .kernPressure=1};
        [c setValue:[NSValue valueWithBytes:&sys objCType:@encode(SystemState)] forKey:@"sys"];
        BatteryState b = {.valid=YES, .percent=85, .acConnected=YES, .isCharging=YES,
            .rawMax_mAh=4500, .designCap_mAh=5000, .voltage_mV=12000, .amperage_mA=1000};
        [c setValue:[NSValue valueWithBytes:&b objCType:@encode(BatteryState)] forKey:@"bat"];
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
        [c rebuildContent];
        NSView *root = p.contentViewController.view;
        printf("Popover: %.0f × %.0f; gauges: %lu; scroll: %s\n",root.frame.size.width, root.frame.size.height,
               (unsigned long)CountGauges(root), FirstScrollView(root) ? "yes" : "no");
        if (FirstScrollView(root) || root.frame.size.height > 564 || CountGauges(root) != 5 ||
            HasText(root,@"bengalfox") || !HasText(root,@"stale 1h")) return Fail(__LINE__);
        if (HasText(root, @"STORAGE") || HasText(root, @"BATTERY") || HasText(root, @"SYSTEM") ||
            HasText(root, @"SOUND") || HasText(root, @"AI STATUS") ||
            FindIdentifier(root, @"popover.heading.storage") || FindIdentifier(root, @"popover.storage.details") ||
            HasText(root, @"drives")) return Fail(__LINE__);
        if (!InstrumentRowsFit(root) || !FitsChildren(root)) return Fail(__LINE__);
        NSView *storageGauge = FindIdentifier(root, @"popover.storage.gauge");
        NSView *batteryGauge = FindIdentifier(root, @"popover.battery.gauge");
        NSView *codexGauge = FindIdentifier(root, @"popover.ai.codex.gauge");
        NSView *cursorGauge = FindIdentifier(root, @"popover.ai.cursor.gauge");
        ClaudeGauge *meter = FindClaudeMeter(root);
        if (!SameColumn(storageGauge, batteryGauge) || !SameColumn(storageGauge, meter) ||
            !SameColumn(storageGauge, codexGauge) || !SameColumn(storageGauge, cursorGauge)) return Fail(__LINE__);
        if (!SameColumn(FindIdentifier(root, @"popover.storage.value"), FindIdentifier(root, @"popover.battery.value")) ||
            !SameColumn(FindIdentifier(root, @"popover.storage.value"), FindIdentifier(root, @"popover.claude.value")) ||
            !SameColumn(FindIdentifier(root, @"popover.storage.value"), FindIdentifier(root, @"popover.ai.codex.value")))
            return Fail(__LINE__);
        NSView *output = FindIdentifier(root, @"popover.sound");
        if (!SoundRow(root, @"Liked Music", @"Shuffle · YouTube Music", NO) ||
            ![output.accessibilityLabel isEqual:@"Sound output, Bose Flex SoundLink"] ||
            ![output.toolTip isEqual:@"Bose Flex SoundLink"]) return Fail(__LINE__);
        // The footer carries exactly two controls plus the ⋯ menu, side by side, none clipped.
        NSView *keep = FindIdentifier(p.contentViewController.view, @"popover.keepAwake");
        NSView *low = FindIdentifier(p.contentViewController.view, @"popover.lowPower");
        NSView *more = FindIdentifier(p.contentViewController.view, @"popover.more");
        if (!keep || !low || !more || NSMaxX(keep.frame) > NSMinX(low.frame) || NSMaxX(low.frame) > NSMinX(more.frame) ||
            !FitsChildren(keep.superview)) return Fail(__LINE__);
        // One figure: the account weekly across all models (33%). No Fable figure, and the
        // 5-hour window never caps it. The weekly reset is on the tooltip, not a caption.
        if (!meter || meter.fable >= 0 || fabs(meter.opus-0.33)>0.001 || !HasText(root,@"33%") ||
            HasText(root,@"Fable") || HasText(root, @"5-hour") || HasText(root, @" left")) return Fail(__LINE__);
        if (!HasTip(root, @"Week resets tomorrow")) return Fail(__LINE__);
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
        NSScrollView *storage = [c storageDetailsView];
        if (!HasText(storage.documentView, @"External 6")) return Fail(__LINE__);
        NSScrollView *ai = [c aiDetailsView];
        if (!HasText(ai.documentView, @"weekly")) return Fail(__LINE__);
        const char *musicState = getenv("GLANCEBAR_MUSIC_STATE");
        if (musicState && strcmp(musicState, "playing") == 0) {
            [c setValue:@YES forKey:@"ytTabOpen"];
            [c setValue:@YES forKey:@"playbackKnown"];
            [c setValue:@YES forKey:@"playbackPlaying"];
            [c setValue:@"Midnight City" forKey:@"ytTitle"];
            [c setValue:@"M83" forKey:@"ytArtist"];
            [c setValue:@83 forKey:@"trackElapsed"];
            [c setValue:@243 forKey:@"trackDuration"];
            [c setValue:@[
                @{@"uid": @"speakers", @"name": @"MacBook Air Speakers",
                  @"transport": @(GlanceAudioTransportBuiltIn), @"outputChannels": @2, @"dataSource": @""},
                @{@"uid": @"bose", @"name": @"Bose Flex SoundLink",
                  @"transport": @(GlanceAudioTransportBluetooth), @"outputChannels": @2, @"dataSource": @""}
            ] forKey:@"audioDevices"];
            [c setValue:@"speakers" forKey:@"defaultOutputUID"];
            [c rebuildContent];
            root = p.contentViewController.view;
            NSView *playingOut = FindIdentifier(root, @"popover.sound");
            if (!SoundRow(root, @"Midnight City", @"M83 · 1:23 / 4:03", YES) || !FitsChildren(root) ||
                ![playingOut.toolTip containsString:@"click for"] ||
                ![playingOut.accessibilityLabel isEqual:@"Sound output, MacBook Air Speakers"])
                return Fail(__LINE__);
        } else if (musicState && strcmp(musicState, "idle") == 0) {
            [c setValue:@NO forKey:@"ytTabOpen"];
            [c setValue:@NO forKey:@"playbackKnown"];
            [c setValue:@NO forKey:@"playbackPlaying"];
            [c rebuildContent];
            root = p.contentViewController.view;
            if (!SoundRow(root, @"Liked Music", @"Shuffle · YouTube Music", NO) || !FitsChildren(root))
                return Fail(__LINE__);
        }
        if (argc > 1) {
            root.appearance = [NSAppearance appearanceNamed:(argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua)];
            NSBitmapImageRep *rep = [root bitmapImageRepForCachingDisplayInRect:root.bounds];
            [root cacheDisplayInRect:root.bounds toBitmapImageRep:rep];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES];
        }
        // Rebuild in place must keep navigation reachable and not accumulate rows.
        [c rebuildContent];
        if (CountGauges(p.contentViewController.view) != 5) return Fail(__LINE__);
        AIUsage *codex = usage[1]; codex.billingNote = @"Requests now bill to credits · balance 20";
        [c rebuildContent];
        if (!HasTip(p.contentViewController.view, @"Using credits")) return Fail(__LINE__);
        // Missing and stale provider data must stay compact without faking a healthy bar.
        AIUsage *missing = usage.lastObject; missing.limitStatusAvailable = NO;
        missing.remainingFraction = -1; missing.resetAt = nil; missing.statusReason = @"Account unavailable";
        [c rebuildContent];
        if (CountGauges(p.contentViewController.view) != 4 ||
            !HasTip(p.contentViewController.view, @"Account unavailable") ||
            !HasText(p.contentViewController.view, @"unavailable")) return Fail(__LINE__);
        meter = FindClaudeMeter(p.contentViewController.view);
        AIUsage *claude = usage[0];
        claude.limitWindows = @[@{@"remainingFraction":@0.82, @"window":@"weekly Fable"}];
        [c rebuildContent];
        ClaudeGauge *updated = FindClaudeMeter(p.contentViewController.view);
        // Only a Fable window reported: no all-models weekly figure, so no fill at all (never Fable's).
        if (updated != meter || updated.fable >= 0 || updated.opus != -1) return Fail(__LINE__);
        claude.limitWindows = @[];
        [c rebuildContent];
        if (HasText(p.contentViewController.view, @"Fable") || CountGauges(p.contentViewController.view) != 4 ||
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
        return 0;
    }
}
