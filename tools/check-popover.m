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
static BOOL SameSize(NSView *a, NSView *b) {
    return a && b && fabs(a.frame.size.width - b.frame.size.width) < 0.5 &&
        fabs(a.frame.size.height - b.frame.size.height) < 0.5;
}
// Separators and section headers are not actionable. A submenu item (Settings) is.
static BOOL ActionableMenuImages(NSMenu *menu) {
    if (!menu) return NO;
    for (NSMenuItem *item in menu.itemArray) {
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
    NSBitmapImageRep *rep = [host bitmapImageRepForCachingDisplayInRect:host.bounds];
    if (!rep) return NO;
    [host cacheDisplayInRect:host.bounds toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
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
    if ([view isKindOfClass:Gauge.class] || [view isKindOfClass:ClaudeGauge.class]) return view;
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
        @"details.battery.eta.value",
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
            .memTotal=34359738368, .memUsed=17179869184, .memAvailable=17179869184, .kernPressure=1};
        [c setValue:[NSValue valueWithBytes:&sys objCType:@encode(SystemState)] forKey:@"sys"];
        BatteryState b = {.valid=YES, .percent=61, .acConnected=YES, .isCharging=YES,
            .rawCurrent_mAh=2745, .rawMax_mAh=4500, .designCap_mAh=5000, .voltage_mV=12000, .amperage_mA=1000,
            .cycleCount=120, .systemPowerIn_mW=18800, .systemLoad_mW=6800, .adapterWatts=20};
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
        ClaudeGauge *meter = FindClaudeMeter(root);
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
        NSTextField *batteryDatum = (NSTextField *)FindIdentifier(root, @"popover.battery.datum");
        if (![batteryDatum isKindOfClass:NSTextField.class] || ![batteryDatum.stringValue containsString:@"W"] ||
            [batteryDatum.stringValue containsString:@"…"]) return Fail(__LINE__);
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
        int etaMin = ChargeMinutesToTarget(b, 80);
        NSString *etaPhrase = [NSString stringWithFormat:@"%@ to 80%%", FmtDuration(etaMin)];
        NSView *batteryRow = FindIdentifier(root, @"popover.row.battery");
        if (etaMin < 0 || ![batteryRow.toolTip containsString:etaPhrase]) return Fail(__LINE__);
        NSPoint symbolMid = [batterySymbol convertPoint:NSMakePoint(NSMidX(batterySymbol.bounds),
                                                                     NSMidY(batterySymbol.bounds))
                                                  toView:batterySymbol.superview.superview];
        NSView *symbolHit = [batterySymbol.superview hitTest:symbolMid];
        if (symbolHit != batterySymbol) return Fail(__LINE__);
        Gauge *batteryMeter = (Gauge *)batteryGauge;
        if (![batteryMeter isKindOfClass:Gauge.class] || fabs(batteryMeter.markerFraction - 0.80) > 0.001)
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
        if (!HasTip(root, @"Claude —") || !HasTip(root, @"Codex —") || !HasTip(root, @"Cursor —"))
            return Fail(__LINE__);
        NSTextField *claudeDatum = (NSTextField *)FindIdentifier(root, @"popover.ai.claude.datum");
        if (![claudeDatum.stringValue hasPrefix:@"resets "]) return Fail(__LINE__);
        NSView *output = FindIdentifier(root, @"popover.sound");
        if (!SoundRow(root, @"Liked Music", @"Shuffle · YouTube Music", NO) ||
            ![output.accessibilityLabel isEqual:@"Sound output, Bose Flex SoundLink"] ||
            ![output.toolTip isEqual:@"Bose Flex SoundLink"]) return Fail(__LINE__);
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
        AIUsage *history = usage[0];
        history.todayTokens = 12500;
        history.weekTokens = 84000;
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
        if (!reveal || reveal.title.length || !reveal.image || ![reveal.toolTip isEqualToString:@"Reveal in Finder"])
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
        NSTextField *etaValue = (NSTextField *)FindIdentifier(battery.documentView, @"details.battery.eta.value");
        NSTextField *etaDatum = (NSTextField *)FindIdentifier(battery.documentView, @"details.battery.eta.datum");
        if (![etaName.stringValue isEqual:@"To 80%"] || ![etaValue.stringValue isEqual:FmtDuration(etaMin)] ||
            ![etaDatum.stringValue hasPrefix:@"at +"] || ![etaDatum.stringValue containsString:@"W"])
            return Fail(__LINE__);
        NSArray *etaFields = @[etaName, etaValue, etaDatum];
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
            fabs(overviewCharge.markerFraction - 0.80) > 0.001) return Fail(__LINE__);
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
            tabs.tabStyle != NSTabViewControllerTabStyleToolbar || tabs.tabViewItems.count != 5)
            return Fail(__LINE__);
        [c rebuildDetails];   // in-place refresh must keep the symbols and the documents
        if (tabs.tabViewItems.count != 5) return Fail(__LINE__);
        NSSet *idents = [NSSet setWithArray:@[@"overview", @"storage", @"battery", @"system", @"ai"]];
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
        const char *detailsPrefix = getenv("GLANCEBAR_RENDER_DETAILS");
        if (detailsPrefix && detailsPrefix[0]) {
            NSAppearanceName appearance = argc > 2 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua;
            for (NSString *tab in @[@"overview", @"storage", @"battery", @"system", @"ai"]) {
                NSScrollView *scroll = [c detailViewForIdentifier:tab];
                NSView *doc = [scroll isKindOfClass:NSScrollView.class] ? scroll.documentView : scroll;
                NSString *path = [NSString stringWithFormat:@"%s-%@.png", detailsPrefix, tab];
                if (!RenderOffscreen(doc, path, appearance)) return Fail(__LINE__);
            }
        }
        [c setValue:nil forKey:@"detailsWindow"];
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
