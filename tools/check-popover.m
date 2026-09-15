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
        [c rebuildContent];
        NSView *root = p.contentViewController.view;
        printf("Popover: %.0f × %.0f; gauges: %lu; scroll: %s\n",root.frame.size.width, root.frame.size.height,
               (unsigned long)CountGauges(root), FirstScrollView(root) ? "yes" : "no");
        if (FirstScrollView(root) || root.frame.size.height > 500 || CountGauges(root) != 5 ||
            HasText(root,@"bengalfox") || !HasText(root,@"cached")) return Fail(__LINE__);
        if (!FitsChildren(root)) return Fail(__LINE__);
        ClaudeGauge *meter = FindClaudeMeter(root);
        // Opus has no window of its own, so it shares the Fable tier window (6%), and
        // the account weekly (33%) only caps — it never stands in for a model figure.
        if (!meter || fabs(meter.fable-0.06)>0.001 || fabs(meter.opus-0.06)>0.001 ||
            meter.frame.origin.x != 98 || meter.frame.size.width != 126 || !HasText(root,@"6/6%")) return Fail(__LINE__);
        // The 5-hour window is a different clock: named in the caption, never a cap.
        if (!HasText(root, @"5h 57% left")) return Fail(__LINE__);
        if (!HasText(root, @"Macintosh HD")) return Fail(__LINE__);
        NSScrollView *storage = [c storageDetailsView];
        if (!HasText(storage.documentView, @"External 6")) return Fail(__LINE__);
        NSScrollView *ai = [c aiDetailsView];
        if (!HasText(ai.documentView, @"weekly")) return Fail(__LINE__);
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
        if (!HasText(p.contentViewController.view, @"Using credits")) return Fail(__LINE__);
        // Missing and stale provider data must stay compact without faking a healthy bar.
        AIUsage *missing = usage.lastObject; missing.limitStatusAvailable = NO;
        missing.remainingFraction = -1; missing.resetAt = nil; missing.statusReason = @"Account unavailable";
        [c rebuildContent];
        if (CountGauges(p.contentViewController.view) != 4 ||
            !HasText(p.contentViewController.view, @"Account unavailable")) return Fail(__LINE__);
        meter = FindClaudeMeter(p.contentViewController.view);
        AIUsage *claude = usage[0];
        claude.limitWindows = @[@{@"remainingFraction":@0.82, @"window":@"weekly Fable"}];
        [c rebuildContent];
        ClaudeGauge *updated = FindClaudeMeter(p.contentViewController.view);
        if (updated != meter || fabs(updated.fable-0.82)>0.001 || fabs(updated.opus-0.82)>0.001) return Fail(__LINE__);
        claude.limitWindows = @[];
        [c rebuildContent];
        if (HasText(p.contentViewController.view, @"Fable") || CountGauges(p.contentViewController.view) != 4 ||
            !FitsChildren(p.contentViewController.view)) return Fail(__LINE__);
        claude.limitWindows = @[@{@"remainingFraction":@0.82, @"window":@"weekly Fable"}];
        claude.limitWindows = @[@{@"remainingFraction":@1, @"window":@"weekly Fable"},
                               @{@"remainingFraction":@1, @"window":@"weekly Opus"}];
        [c rebuildContent];
        if (!HasText(p.contentViewController.view,@"100/100%") || !FitsChildren(p.contentViewController.view)) return Fail(__LINE__);
        claude.overageActive = YES;
        [c rebuildContent];
        if (HasText(p.contentViewController.view, @"Fable") || !FitsChildren(p.contentViewController.view)) return Fail(__LINE__);
        return 0;
    }
}
