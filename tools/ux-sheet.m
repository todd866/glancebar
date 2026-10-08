// Design sheet: render candidate instrument designs side by side, light and dark, at the
// real popover geometry, so options are judged as pictures before anything ships.
// Usage: ux-sheet <out.png>. Each variant is a column; rows use live-shaped data.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#pragma clang diagnostic ignored "-Watomic-property-with-user-defined-accessor"
#pragma clang diagnostic ignored "-Wunused-parameter"
#define main GlancebarApplicationMain
#import "../Sources/main.m"
#undef main
#pragma clang diagnostic pop

static const CGFloat kCursorRowH = 32, kCursorGaugeH = 20;   // the retired two-lane geometry, for comparison sheets

typedef NS_ENUM(NSInteger, PaceStyle) { PaceNone, PaceTick, PaceDeficit, PaceTrend, PaceUsed, PaceShortfallOnly };

// One lane or a pair of lanes, drawn with one of the candidate pace treatments.
@interface PaceSketchGauge : NSView
@property (nonatomic, copy) NSArray<NSNumber *> *fractions;   // remaining, one per lane
@property (nonatomic) double pace;                            // time remaining in the window, 0…1
@property (nonatomic) PaceStyle style;
@end
@implementation PaceSketchGauge
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirty {
    NSRect r = self.bounds;
    NSUInteger n = self.fractions.count;
    CGFloat laneH = n == 2 ? 4 : kGaugeH, gap = n == 2 ? 12 : 0;
    CGFloat blockH = n * laneH + (n - 1) * gap, y0 = NSMidY(r) - blockH / 2;
    CGFloat w = NSWidth(r);
    double elapsed = 1 - _pace;
    for (NSUInteger i = 0; i < n; i++) {
        double left = self.fractions[i].doubleValue;
        NSRect lane = NSMakeRect(0, y0 + (n - 1 - i) * (laneH + gap), w, laneH);
        CGFloat rad = laneH / 2;
        NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:lane xRadius:rad yRadius:rad];
        [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [track fill];
        [NSGraphicsContext saveGraphicsState]; [track addClip];
        if (_style == PaceUsed) {
            // Used grows left to right; the elapsed-time line moves left to right with it.
            double used = 1 - left;
            CGFloat lineX = w * elapsed;
            [AIQuotaColor(left) setFill];
            NSRectFill(NSMakeRect(0, NSMinY(lane), MIN(w * used, lineX), laneH));
            if (w * used > lineX) {
                [NSColor.systemRedColor setFill];
                NSRectFill(NSMakeRect(lineX, NSMinY(lane), w * used - lineX, laneH));
            }
        } else {
            NSColor *color = AIQuotaColor(left);
            [color setFill]; NSRectFill(NSMakeRect(0, NSMinY(lane), MAX(laneH, w * left), laneH));
            if ((_style == PaceDeficit || _style == PaceShortfallOnly) && left < _pace) {
                // The shortfall itself: track between the fill's end and where time says it should be.
                [[NSColor.systemRedColor colorWithAlphaComponent:0.35] setFill];
                NSRectFill(NSMakeRect(w * left, NSMinY(lane), w * (_pace - left), laneH));
            }
            if (_style == PaceTrend && elapsed > 0.05 && left < 1) {
                // Trend vector: where the fill will be at the reset at this window's average burn.
                double atReset = left - (1 - left) * _pace / elapsed;
                CGFloat from = w * MAX(0, atReset), to = w * left;
                [(atReset <= 0 ? NSColor.systemRedColor : NSColor.labelColor) setFill];
                NSRectFill(NSMakeRect(from, NSMidY(lane) - 1, to - from, 2));
            }
        }
        [NSGraphicsContext restoreGraphicsState];
    }
    BOOL behind = NO;
    for (NSNumber *f in self.fractions) if (f.doubleValue < _pace) behind = YES;
    if (_style == PaceTick || _style == PaceDeficit || _style == PaceUsed || (_style == PaceShortfallOnly && behind)) {
        // A vertical bar through the lanes, like a bug on a tape.
        CGFloat x = round(w * (_style == PaceUsed ? elapsed : _pace)) - 1;
        [NSColor.labelColor setFill];
        NSRectFill(NSMakeRect(x, y0 - 3, 2, blockH + 6));
    }
}
@end

static NSView *SheetRow(NSString *name, NSArray<NSNumber *> *fractions, double pace, NSString *datum,
                        PaceStyle style, Controller *c) {
    CGFloat h = fractions.count == 2 ? kCursorRowH : kRowH;
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, h)];
    NSImageView *logo = [NSImageView imageViewWithImage:AIProviderLogo(name, kLeadSymbol) ?: [NSImage new]];
    logo.frame = NSMakeRect(kPad, (h - kLeadSymbol) / 2, kLeadW, kLeadSymbol);
    [row addSubview:logo];
    [row addSubview:[c text:name font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:NSColor.labelColor
                         at:NSMakeRect(kAINameX, (h - 16) / 2, kAINameW, 16) align:NSTextAlignmentLeft]];
    CGFloat gaugeH = fractions.count == 2 ? kCursorGaugeH : 16;
    PaceSketchGauge *g = [[PaceSketchGauge alloc] initWithFrame:NSMakeRect(kGaugeX, (h - gaugeH) / 2, kGaugeW, gaugeH)];
    g.fractions = fractions; g.pace = pace; g.style = style;
    [row addSubview:g];
    if (fractions.count == 2) {
        for (NSUInteger i = 0; i < 2; i++) {
            double f = fractions[i].doubleValue;
            [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", f * 100]
                               font:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold]
                              color:AIQuotaColor(f) at:NSMakeRect(kValueX, i == 0 ? h / 2 : 0, kValueW, h / 2)
                              align:NSTextAlignmentRight]];
        }
    } else {
        double f = fractions[0].doubleValue;
        [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", f * 100]
                           font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                          color:AIQuotaColor(f) at:NSMakeRect(kValueX, (h - kValueH) / 2, kValueW, kValueH)
                          align:NSTextAlignmentRight]];
    }
    [row addSubview:[c text:datum font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular]
                      color:NSColor.secondaryLabelColor at:NSMakeRect(kDatumX, (h - kDatumH) / 2, kDatumW, kDatumH)
                      align:NSTextAlignmentLeft]];
    return row;
}

static NSView *SheetPanel(NSString *title, PaceStyle style, NSAppearanceName look, Controller *c) {
    // Live readings at 08:08 Thu 8 Oct, plus one on-track row for contrast.
    NSArray *rows = @[
        @[@"Claude", @[@0.45], @0.79, @"resets Tue"],
        @[@"Codex", @[@0.52], @0.88, @"resets Wed"],
        @[@"Cursor", @[@0.17, @0.41], @0.86, @"resets 3 Nov"],
        @[@"Claude", @[@0.70], @0.40, @"resets Tue"],   // on track: Saturday at the same total
    ];
    CGFloat titleH = 26, y = 8, height = titleH + 8;
    for (NSArray *r in rows) height += [r[1] count] == 2 ? kCursorRowH : kRowH;
    height += 18;
    PopoverRootView *panel = [[PopoverRootView alloc] initWithFrame:NSMakeRect(0, 0, kW, height)];
    panel.appearance = [NSAppearance appearanceNamed:look];
    NSTextField *caption = [c text:title font:[NSFont systemFontOfSize:12 weight:NSFontWeightBold]
                             color:NSColor.secondaryLabelColor at:NSMakeRect(kPad, y, kW - 2 * kPad, 16)
                             align:NSTextAlignmentLeft];
    [panel addSubview:caption];
    y += titleH;
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSArray *r = rows[i];
        if (i == 3) {   // separate the contrast example
            NSBox *rule = [[NSBox alloc] initWithFrame:NSMakeRect(kPad, y + 4, kW - 2 * kPad, 1)];
            rule.boxType = NSBoxSeparator; [panel addSubview:rule]; y += 10;
        }
        NSView *row = SheetRow(r[0], r[1], [r[2] doubleValue], r[3], style, c);
        NSRect f = row.frame; f.origin.y = y; row.frame = f;
        [panel addSubview:row];
        y += NSHeight(f);
    }
    NSRect pf = panel.frame; pf.size.height = y + 8; panel.frame = pf;
    return panel;
}

// Lays variant panels out as a grid: one row per variant, light on the left, dark on the right.
static BOOL WriteSheet(NSArray<NSView *(^)(NSAppearanceName)> *builders, NSString *path) {
    CGFloat gap = 16, colW = kW, rowH = 0;
    NSMutableArray *panels = [NSMutableArray array];
    for (NSView *(^build)(NSAppearanceName) in builders) {
        NSView *light = build(NSAppearanceNameAqua), *dark = build(NSAppearanceNameDarkAqua);
        [panels addObject:@[light, dark]];
        rowH = MAX(rowH, NSHeight(light.frame));
    }
    FlippedView *sheet = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, gap + 2 * (colW + gap), gap + panels.count * (rowH + gap))];
    sheet.wantsLayer = YES;
    sheet.layer.backgroundColor = [NSColor colorWithWhite:0.55 alpha:1].CGColor;
    for (NSUInteger i = 0; i < panels.count; i++)
        for (NSUInteger j = 0; j < 2; j++) {
            NSView *p = panels[i][j];
            p.frame = NSMakeRect(gap + j * (colW + gap), gap + i * (rowH + gap), colW, rowH);
            [sheet addSubview:p];
        }
    NSBitmapImageRep *rep = [sheet bitmapImageRepForCachingDisplayInRect:sheet.bounds];
    [sheet cacheDisplayInRect:sheet.bounds toBitmapImageRep:rep];
    return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

// A titled panel of rows on the popover's own background.
static NSView *TitledPanel(NSString *title, NSArray<NSView *> *rows, NSAppearanceName look, Controller *c) {
    CGFloat y = 8;
    PopoverRootView *panel = [[PopoverRootView alloc] initWithFrame:NSMakeRect(0, 0, kW, 400)];
    panel.appearance = [NSAppearance appearanceNamed:look];
    [panel addSubview:[c text:title font:[NSFont systemFontOfSize:12 weight:NSFontWeightBold] color:NSColor.secondaryLabelColor
                           at:NSMakeRect(kPad, y, kW - 2 * kPad, 16) align:NSTextAlignmentLeft]];
    y += 26;
    for (NSView *row in rows) { NSRect f = row.frame; f.origin.y = y; row.frame = f; [panel addSubview:row]; y += NSHeight(f); }
    NSRect pf = panel.frame; pf.size.height = y + 8; panel.frame = pf;
    return panel;
}

#pragma mark - Power flow sheet

typedef NS_ENUM(NSInteger, FlowStyle) { FlowText, FlowBalance, FlowSplit, FlowSplitTime, FlowLane };

// Where the Mac's power comes from, on one bar: grey is what the charger covers, orange what
// the battery covers, green the charger's surplus going into the battery. Scale is fixed.
@interface FlowSketch : NSView
@property (nonatomic) double inW, loadW, scale;
@property (nonatomic) BOOL balance;   // centre-zero: battery in (green, right) vs out (orange, left)
@end
@implementation FlowSketch
- (void)drawRect:(NSRect)dirty {
    NSRect r = self.bounds; CGFloat h = NSHeight(r), rad = h / 2, w = NSWidth(r);
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad];
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [track fill];
    [NSGraphicsContext saveGraphicsState]; [track addClip];
    double batt = _inW - _loadW;   // + into the battery, − out of it
    if (_balance) {
        CGFloat mid = w / 2, len = MIN(fabs(batt) / _scale, 1) * mid;
        [(batt >= 0 ? NSColor.systemGreenColor : NSColor.systemOrangeColor) setFill];
        NSRectFill(batt >= 0 ? NSMakeRect(mid, 0, len, h) : NSMakeRect(mid - len, 0, len, h));
        [NSGraphicsContext restoreGraphicsState];
        [NSColor.labelColor setFill]; NSRectFill(NSMakeRect(mid - 0.75, -2, 1.5, h + 4));
        return;
    }
    __block CGFloat x = 0;
    void (^seg)(double, NSColor *) = ^(double watts, NSColor *color) {
        if (watts <= 0) return;
        CGFloat len = MIN(watts / self->_scale * w, w - x);
        [color setFill]; NSRectFill(NSMakeRect(x, 0, MAX(len - 1, 0.5), h));
        x += len;
    };
    seg(MIN(_inW, _loadW), NSColor.systemGrayColor);               // the Mac, on the charger
    if (batt < 0) seg(-batt, NSColor.systemOrangeColor);            // the Mac, on the battery
    else seg(batt, NSColor.systemGreenColor);                       // surplus into the battery
    [NSGraphicsContext restoreGraphicsState];
}
@end

static NSView *PowerRow(Controller *c, BatteryState b, NSString *time, FlowStyle style) {
    [c setValue:[NSValue valueWithBytes:&b objCType:@encode(BatteryState)] forKey:@"bat"];
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
    NSImage *glyph = [c liveBatteryGlyph];
    NSImageView *iv = [NSImageView imageViewWithImage:glyph];
    iv.imageScaling = NSImageScaleProportionallyDown;
    if (glyph.template) iv.contentTintColor = PowerFlowColor(b, NSColor.labelColor);
    iv.frame = NSMakeRect(kPad, (kRowH - kLeadSymbol) / 2, kLeadW, kLeadSymbol);
    [row addSubview:iv];
    [row addSubview:[c text:@"Battery" font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:NSColor.labelColor
                         at:NSMakeRect(kAINameX, (kRowH - 16) / 2, kAINameW, 16) align:NSTextAlignmentLeft]];
    double inW = b.systemPowerIn_mW / 1000.0, loadW = b.systemLoad_mW / 1000.0, battW = inW - loadW;
    if (style == FlowLane) {
        // Charge on the top lane, power flow on the lower lane: one instrument, two readings.
        Gauge *charge = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, kRowH / 2 + 2, kGaugeW, 6)];
        charge.fraction = b.percent / 100.0; charge.color = BattBarColor(b.percent); charge.markerFraction = 0.8;
        [row addSubview:charge];
        FlowSketch *flow = [[FlowSketch alloc] initWithFrame:NSMakeRect(kGaugeX, kRowH / 2 - 7, kGaugeW, 4)];
        flow.inW = inW; flow.loadW = loadW; flow.scale = 30;
        [row addSubview:flow];
    } else {
        Gauge *charge = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2, kGaugeW, kGaugeH)];
        charge.fraction = b.percent / 100.0; charge.color = BattBarColor(b.percent); charge.markerFraction = 0.8;
        [row addSubview:charge];
    }
    [row addSubview:[c text:[NSString stringWithFormat:@"%d%%", b.percent]
                       font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                      color:BattBarColor(b.percent) at:NSMakeRect(kValueX, (kRowH - kValueH) / 2, kValueW, kValueH)
                      align:NSTextAlignmentRight]];
    NSFont *datumFont = [NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular];
    NSColor *flowColor = battW > 0.3 ? NSColor.systemGreenColor : battW < -0.5 ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    if (style == FlowText) {
        NSString *w = fabs(battW) < 0.3 ? @"held 80%" : [NSString stringWithFormat:@"%+.0f W%@", battW, time ? [@" · " stringByAppendingString:time] : @""];
        [row addSubview:[c text:w font:datumFont color:flowColor at:NSMakeRect(kDatumX, (kRowH - kDatumH) / 2, kDatumW, kDatumH) align:NSTextAlignmentLeft]];
    } else if (style == FlowBalance || style == FlowSplit) {
        FlowSketch *flow = [[FlowSketch alloc] initWithFrame:NSMakeRect(kDatumX, (kRowH - kGaugeH) / 2, kDatumW - 6, kGaugeH)];
        flow.inW = inW; flow.loadW = loadW; flow.scale = style == FlowBalance ? 20 : 30; flow.balance = style == FlowBalance;
        [row addSubview:flow];
    } else if (style == FlowSplitTime) {
        FlowSketch *flow = [[FlowSketch alloc] initWithFrame:NSMakeRect(kDatumX, (kRowH - kGaugeH) / 2, 50, kGaugeH)];
        flow.inW = inW; flow.loadW = loadW; flow.scale = 30;
        [row addSubview:flow];
        if (time) [row addSubview:[c text:time font:datumFont color:flowColor
                                         at:NSMakeRect(kDatumX + 54, (kRowH - kDatumH) / 2, kDatumW - 54, kDatumH) align:NSTextAlignmentLeft]];
    } else if (style == FlowLane && time) {
        [row addSubview:[c text:time font:datumFont color:flowColor at:NSMakeRect(kDatumX, (kRowH - kDatumH) / 2, kDatumW, kDatumH) align:NSTextAlignmentLeft]];
    }
    return row;
}

static BOOL PowerSheet(NSString *path) {
    Controller *c = [Controller new];
    BatteryState base = {.valid=YES, .rawCurrent_mAh=2745, .rawMax_mAh=4500, .designCap_mAh=5000, .voltage_mV=12000,
                         .cycleCount=120, .adapterWatts=30};
    // in W, load W, percent, AC, charging, time — battery W follows from in − load.
    NSArray *states = @[@[@26, @9, @42, @YES, @YES, @"0:51"],      // charging hard
                        @[@9, @9, @80, @YES, @NO, [NSNull null]],  // held at the limit
                        @[@4, @11.9, @78, @YES, @NO, [NSNull null]],  // plugged, battery carrying the rest (now)
                        @[@0, @13.2, @63, @NO, @NO, @"3:12"]];     // on battery
    NSArray *variants = @[@[@"A  today: words", @(FlowText)],
                          @[@"B  centre-zero: battery in → green, out ← orange", @(FlowBalance)],
                          @[@"C  where the power comes from: charger grey, battery orange, surplus green", @(FlowSplit)],
                          @[@"D  C plus time", @(FlowSplitTime)],
                          @[@"E  flow as a second lane under charge, time beside", @(FlowLane)]];
    NSMutableArray *builders = [NSMutableArray array];
    for (NSArray *v in variants) {
        [builders addObject:^NSView *(NSAppearanceName look) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSArray *st in states) {
                BatteryState b = base;
                b.systemPowerIn_mW = (long)([st[0] doubleValue] * 1000); b.systemLoad_mW = (long)([st[1] doubleValue] * 1000);
                b.percent = [st[2] intValue]; b.acConnected = [st[3] boolValue]; b.isCharging = [st[4] boolValue];
                b.amperage_mA = (long)(([st[0] doubleValue] - [st[1] doubleValue]) * 1000 / 12.0);
                [rows addObject:PowerRow(c, b, st[5] == [NSNull null] ? nil : st[5], [v[1] integerValue])];
            }
            return TitledPanel(v[0], rows, look, c);
        }];
    }
    return WriteSheet(builders, path);
}

#pragma mark - System row sheet

typedef NS_ENUM(NSInteger, SysStyle) { SysToday, SysMemBar, SysMemBarQuiet, SysLanes };

// Memory as a mini bar in the datum column: fill = memory in use, tinted by the kernel's
// pressure verdict; swap, when there is any, is a red overflow at the right end.
@interface MemSketch : NSView
@property (nonatomic) double used, swapFrac;
@property (nonatomic, strong) NSColor *color;
@end
@implementation MemSketch
- (void)drawRect:(NSRect)dirty {
    NSRect r = self.bounds; CGFloat h = NSHeight(r), w = NSWidth(r);
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:r xRadius:h / 2 yRadius:h / 2];
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [track fill];
    [NSGraphicsContext saveGraphicsState]; [track addClip];
    CGFloat swapW = MIN(_swapFrac, 0.4) * w;
    [_color setFill]; NSRectFill(NSMakeRect(0, 0, MIN(_used, 1) * (w - swapW), h));
    if (swapW > 0) { [NSColor.systemRedColor setFill]; NSRectFill(NSMakeRect(w - swapW, 0, swapW, h)); }
    [NSGraphicsContext restoreGraphicsState];
}
@end

static NSView *SystemRow(Controller *c, double cpu, int pressure, double memUsed, double swapGB, SysStyle style) {
    SystemState sys = {.cpuValid=YES, .memValid=YES, .swapValid=YES, .cpu=cpu, .memTotal=34359738368,
        .memUsed=(uint64_t)(memUsed * 34359738368.0), .memAvailable=(uint64_t)((1 - memUsed) * 34359738368.0),
        .swapUsed=(uint64_t)(swapGB * 1073741824.0), .kernPressure=pressure};
    [c setValue:[NSValue valueWithBytes:&sys objCType:@encode(SystemState)] forKey:@"sys"];
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, style == SysLanes ? kCursorRowH : kRowH)];
    CGFloat h = NSHeight(row.frame);
    NSString *level = MemoryPressureLevel(sys);
    [c instrumentSymbol:@"cpu" tint:SystemPressureColor(SystemPressureLevel(sys)) identifier:@"s" in:row];
    [c instrumentName:@"System" identifier:@"n" in:row];
    if (style == SysToday) {
        [c addSystemInstrumentTo:row gauge:NSMakeRect(kGaugeX, (h - kGaugeH) / 2, kGaugeW, kGaugeH)
                           value:NSMakeRect(kValueX, (h - kValueH) / 2, kValueW, kValueH)
                           datum:NSMakeRect(kDatumX, (h - kDatumH) / 2, kDatumW, kDatumH) stem:@"x" tip:@""];
        return row;
    }
    NSColor *memColor = SystemPressureColor(level);
    if (style == SysLanes) {
        // CPU above, memory below, as one instrument; both values in the value column.
        Gauge *g1 = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, h / 2 + 4, kGaugeW, 4)];
        g1.fraction = cpu; g1.color = CPUColor(cpu); [row addSubview:g1];
        MemSketch *m = [[MemSketch alloc] initWithFrame:NSMakeRect(kGaugeX, h / 2 - 8, kGaugeW, 4)];
        m.used = memUsed; m.swapFrac = swapGB / 16.0; m.color = memColor; [row addSubview:m];
        [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", cpu * 100] font:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold]
                          color:CPUColor(cpu) at:NSMakeRect(kValueX, h / 2, kValueW, h / 2) align:NSTextAlignmentRight]];
        [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", memUsed * 100] font:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold]
                          color:memColor at:NSMakeRect(kValueX, 0, kValueW, h / 2) align:NSTextAlignmentRight]];
        return row;
    }
    Gauge *g = [[Gauge alloc] initWithFrame:NSMakeRect(kGaugeX, (h - kGaugeH) / 2, kGaugeW, kGaugeH)];
    g.fraction = cpu; g.color = CPUColor(cpu); [row addSubview:g];
    [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", cpu * 100] font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                      color:CPUColor(cpu) at:NSMakeRect(kValueX, (h - kValueH) / 2, kValueW, kValueH) align:NSTextAlignmentRight]];
    if (style == SysMemBarQuiet && pressure <= 1 && swapGB == 0) return row;   // silent while memory is fine
    MemSketch *m = [[MemSketch alloc] initWithFrame:NSMakeRect(kDatumX, (h - kGaugeH) / 2, 50, kGaugeH)];
    m.used = memUsed; m.swapFrac = swapGB / 16.0; m.color = memColor;
    [row addSubview:m];
    return row;
}

static BOOL SystemSheet(NSString *path) {
    Controller *c = [Controller new];
    // cpu, kernel pressure (1 low, 2 medium, 4 high), memory in use, swap GB
    NSArray *states = @[@[@0.24, @1, @0.50, @0], @[@0.54, @1, @0.72, @0.6], @[@0.70, @2, @0.88, @3], @[@1.0, @4, @0.97, @9]];
    NSArray *variants = @[@[@"A  today: chip, pressure pips, swap arrows", @(SysToday)],
                          @[@"B  memory as a mini bar beside CPU; swap = red end", @(SysMemBar)],
                          @[@"C  B, but nothing while memory is fine", @(SysMemBarQuiet)],
                          @[@"D  two lanes: CPU above, memory below", @(SysLanes)]];
    NSMutableArray *builders = [NSMutableArray array];
    for (NSArray *v in variants) {
        [builders addObject:^NSView *(NSAppearanceName look) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSArray *st in states)
                [rows addObject:SystemRow(c, [st[0] doubleValue], [st[1] intValue], [st[2] doubleValue], [st[3] doubleValue], [v[1] integerValue])];
            return TitledPanel(v[0], rows, look, c);
        }];
    }
    return WriteSheet(builders, path);
}

#pragma mark - Battery trend sheet (quantity + flow on one bar)

typedef NS_ENUM(NSInteger, TrendStyle) { TrendGhost, TrendVector, TrendChevrons, TrendGhostChevrons };

// The charge bar carries its own flow: where the level will be in an hour at this rate.
@interface TrendSketch : NSView
@property (nonatomic) double level, perHour, limit;   // fractions; perHour signed
@property (nonatomic) TrendStyle style;
@end
@implementation TrendSketch
- (void)drawRect:(NSRect)dirty {
    NSRect r = self.bounds; CGFloat w = NSWidth(r), h = NSHeight(r), rad = h / 2;
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad];
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [track fill];
    double target = _perHour >= 0 ? MIN(_level + _perHour, _limit > 0 ? MAX(_limit, _level) : 1) : MAX(0, _level + _perHour);
    BOOL charging = _perHour > 0.005, draining = _perHour < -0.005;
    NSColor *base = BattBarColor((int)lround(_level * 100));
    [NSGraphicsContext saveGraphicsState]; [track addClip];
    BOOL ghost = _style == TrendGhost || _style == TrendGhostChevrons;
    if (ghost && draining) {
        // What the next hour takes: the end of the fill turns orange.
        [base setFill]; NSRectFill(NSMakeRect(0, 0, w * target, h));
        [NSColor.systemOrangeColor setFill]; NSRectFill(NSMakeRect(w * target, 0, w * (_level - target), h));
    } else {
        [base setFill]; NSRectFill(NSMakeRect(0, 0, MAX(h, w * _level), h));
        if (ghost && charging) {   // what the next hour adds: a pale extension
            [[NSColor.systemGreenColor colorWithAlphaComponent:0.35] setFill];
            NSRectFill(NSMakeRect(w * _level, 0, w * (target - _level), h));
        }
    }
    [NSGraphicsContext restoreGraphicsState];
    if (_limit > 0) { [NSColor.labelColor setFill]; NSRectFill(NSMakeRect(w * _limit - 0.75, 0, 1.5, h)); }
    if (_style == TrendVector && (charging || draining)) {
        // Airspeed-tape trend vector: a line from the level to where it is heading, with a head.
        CGFloat from = w * _level, to = w * target, y = h + 3;
        NSColor *ink = charging ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
        [ink setFill]; NSRectFill(NSMakeRect(MIN(from, to), y - 1, fabs(to - from), 2));
        NSBezierPath *head = [NSBezierPath bezierPath];
        CGFloat dir = charging ? 1 : -1;
        [head moveToPoint:NSMakePoint(to + dir * 4, y)];
        [head lineToPoint:NSMakePoint(to - dir * 1, y + 3.5)];
        [head lineToPoint:NSMakePoint(to - dir * 1, y - 3.5)];
        [head closePath]; [head fill];
    }
    if ((_style == TrendChevrons || _style == TrendGhostChevrons) && (charging || draining)) {
        // Chevrons ride on the bar at the level, pointing the way it moves; more for faster.
        int n = fabs(_perHour) > 0.30 ? 3 : fabs(_perHour) > 0.12 ? 2 : 1;
        NSColor *ink = charging ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
        CGFloat x0 = w * _level + (charging ? 4 : -4), step = 6;
        NSBezierPath *p = [NSBezierPath bezierPath]; p.lineWidth = 1.8; p.lineCapStyle = NSLineCapStyleRound; p.lineJoinStyle = NSLineJoinStyleRound;
        for (int i = 0; i < n; i++) {
            CGFloat x = charging ? x0 + i * step : x0 - i * step, d = charging ? 3 : -3;
            [p moveToPoint:NSMakePoint(x, h / 2 + 4)]; [p lineToPoint:NSMakePoint(x + d, h / 2)]; [p lineToPoint:NSMakePoint(x, h / 2 - 4)];
        }
        [(ghost ? NSColor.labelColor : ink) setStroke]; [p stroke];
    }
}
@end

static NSView *TrendRow(Controller *c, int pct, double watts, BOOL ac, NSString *time, TrendStyle style) {
    BatteryState b = {.valid=YES, .percent=pct, .acConnected=ac, .isCharging=watts > 0.3, .rawCurrent_mAh=4500 * pct / 100,
        .rawMax_mAh=4500, .designCap_mAh=5000, .voltage_mV=12000, .amperage_mA=(long)(watts * 1000 / 12.0),
        .systemPowerIn_mW=ac ? (long)((9 + MAX(watts, -5)) * 1000) : 0, .systemLoad_mW=9000, .adapterWatts=ac ? 30 : 0};
    [c setValue:[NSValue valueWithBytes:&b objCType:@encode(BatteryState)] forKey:@"bat"];
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, kRowH)];
    NSImage *glyph = [c liveBatteryGlyph];
    NSImageView *iv = [NSImageView imageViewWithImage:glyph];
    iv.imageScaling = NSImageScaleProportionallyDown;
    if (glyph.template) iv.contentTintColor = PowerFlowColor(b, NSColor.labelColor);
    iv.frame = NSMakeRect(kPad, (kRowH - kLeadSymbol) / 2, kLeadW, kLeadSymbol);
    [row addSubview:iv];
    [row addSubview:[c text:@"Battery" font:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold] color:NSColor.labelColor
                         at:NSMakeRect(kAINameX, (kRowH - 16) / 2, kAINameW, 16) align:NSTextAlignmentLeft]];
    TrendSketch *t = [[TrendSketch alloc] initWithFrame:NSMakeRect(kGaugeX, (kRowH - kGaugeH) / 2, kGaugeW, kGaugeH)];
    t.level = pct / 100.0; t.perHour = watts / 54.0; t.limit = ac ? 0.8 : 0; t.style = style;
    [row addSubview:t];
    [row addSubview:[c text:[NSString stringWithFormat:@"%d%%", pct] font:[NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold]
                      color:BattBarColor(pct) at:NSMakeRect(kValueX, (kRowH - kValueH) / 2, kValueW, kValueH) align:NSTextAlignmentRight]];
    if (time) [row addSubview:[c text:time font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular]
                                color:watts > 0 ? NSColor.systemGreenColor : NSColor.systemOrangeColor
                                   at:NSMakeRect(kDatumX, (kRowH - kDatumH) / 2, kDatumW, kDatumH) align:NSTextAlignmentLeft]];
    return row;
}

static BOOL TrendSheet(NSString *path) {
    Controller *c = [Controller new];
    // percent, battery watts (+ in), on AC, time
    NSArray *states = @[@[@42, @17, @YES, @"0:51"], @[@80, @0, @YES, [NSNull null]], @[@78, @-8, @YES, [NSNull null]],
                        @[@63, @-13, @NO, @"2:30"], @[@30, @-29, @NO, @"0:11"]];
    NSArray *variants = @[@[@"A  ghost: next hour shown on the bar (pale = coming, orange = going)", @(TrendGhost)],
                          @[@"B  trend vector: arrow from the level to where it'll be in an hour", @(TrendVector)],
                          @[@"C  chevrons at the level: direction, and 1-3 for rate", @(TrendChevrons)],
                          @[@"D  ghost + chevrons", @(TrendGhostChevrons)]];
    NSMutableArray *builders = [NSMutableArray array];
    for (NSArray *v in variants) {
        [builders addObject:^NSView *(NSAppearanceName look) {
            NSMutableArray *rows = [NSMutableArray array];
            for (NSArray *st in states)
                [rows addObject:TrendRow(c, [st[0] intValue], [st[1] doubleValue], [st[2] boolValue],
                                         st[3] == [NSNull null] ? nil : st[3], [v[1] integerValue])];
            return TitledPanel(v[0], rows, look, c);
        }];
    }
    return WriteSheet(builders, path);
}

#pragma mark - Cursor two-pool sheet

typedef NS_ENUM(NSInteger, PoolStyle) { PoolToday, PoolOverlay, PoolTight, PoolMarker, PoolTwoRows, PoolInnerLine, PoolUnderline, PoolGrokOverlay };

@interface PoolSketch : NSView
@property (nonatomic) double a, b;   // API, Grok/Composer remaining
@property (nonatomic) PoolStyle style;
@end
@implementation PoolSketch
- (void)lane:(NSRect)lane value:(double)v color:(NSColor *)color {
    CGFloat rad = NSHeight(lane) / 2;
    NSBezierPath *t = [NSBezierPath bezierPathWithRoundedRect:lane xRadius:rad yRadius:rad];
    [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill]; [t fill];
    [NSGraphicsContext saveGraphicsState]; [t addClip];
    [color setFill]; NSRectFill(NSMakeRect(NSMinX(lane), NSMinY(lane), MAX(NSHeight(lane), NSWidth(lane) * v), NSHeight(lane)));
    [NSGraphicsContext restoreGraphicsState];
}
- (void)drawRect:(NSRect)dirty {
    NSRect r = self.bounds; CGFloat w = NSWidth(r), mid = NSMidY(r);
    double lo = MIN(_a, _b), hi = MAX(_a, _b);
    switch (_style) {
        case PoolToday:
            [self lane:NSMakeRect(0, mid + 4, w, 4) value:_a color:AIQuotaColor(_a)];
            [self lane:NSMakeRect(0, mid - 8, w, 4) value:_b color:AIQuotaColor(_b)];
            break;
        case PoolTight:
            [self lane:NSMakeRect(0, mid + 0.5, w, 3.5) value:_a color:AIQuotaColor(_a)];
            [self lane:NSMakeRect(0, mid - 4, w, 3.5) value:_b color:AIQuotaColor(_b)];
            break;
        case PoolOverlay: {
            NSRect bar = NSMakeRect(0, mid - 4, w, 8);
            [self lane:bar value:hi color:[AIQuotaColor(hi) colorWithAlphaComponent:0.4]];
            NSBezierPath *t = [NSBezierPath bezierPathWithRoundedRect:bar xRadius:4 yRadius:4];
            [NSGraphicsContext saveGraphicsState]; [t addClip];
            [AIQuotaColor(lo) setFill]; NSRectFill(NSMakeRect(0, mid - 4, MAX(8, w * lo), 8));
            [NSGraphicsContext restoreGraphicsState];
            break;
        }
        case PoolInnerLine: {
            // Grok is the bar; API is a thin line riding inside it, centred.
            [self lane:NSMakeRect(0, mid - 4, w, 8) value:_b color:AIQuotaColor(_b)];
            [[NSColor.labelColor colorWithAlphaComponent:0.85] setFill];
            NSRectFill(NSMakeRect(2, mid - 1, MAX(2, w * _a - 2), 2));
            break;
        }
        case PoolUnderline:
            // Grok is the bar; API is a hairline lane tucked right under it.
            [self lane:NSMakeRect(0, mid - 2, w, 8) value:_b color:AIQuotaColor(_b)];
            [self lane:NSMakeRect(0, mid - 6, w, 2) value:_a color:AIQuotaColor(_a)];
            break;
        case PoolGrokOverlay: {
            // One bar to Grok's level; the API share of it is the solid, darker part.
            NSRect bar = NSMakeRect(0, mid - 4, w, 8);
            [self lane:bar value:_b color:[AIQuotaColor(_b) colorWithAlphaComponent:0.45]];
            NSBezierPath *t = [NSBezierPath bezierPathWithRoundedRect:bar xRadius:4 yRadius:4];
            [NSGraphicsContext saveGraphicsState]; [t addClip];
            [AIQuotaColor(_a) setFill]; NSRectFill(NSMakeRect(0, mid - 4, MAX(8, w * _a), 8));
            [NSGraphicsContext restoreGraphicsState];
            break;
        }
        case PoolMarker:
        case PoolTwoRows:
            [self lane:NSMakeRect(0, mid - 4, w, 8) value:_a color:AIQuotaColor(_a)];
            if (_style == PoolMarker) {
                [NSColor.labelColor setFill];
                NSRectFill(NSMakeRect(round(w * _b) - 1, mid - 6, 2, 12));
            }
            break;
    }
}
@end

static NSView *QuotaRowSketch(Controller *c, NSString *name, NSString *label, double a, double b, NSString *datum, PoolStyle style) {
    BOOL pair = b >= 0 && (style == PoolToday || style == PoolTight);
    CGFloat h = style == PoolToday && b >= 0 ? kCursorRowH : kRowH;
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kW, h)];
    if (name) {
        NSImageView *logo = [NSImageView imageViewWithImage:AIProviderLogo(name, kLeadSymbol) ?: [NSImage new]];
        logo.frame = NSMakeRect(kPad, (h - kLeadSymbol) / 2, kLeadW, kLeadSymbol);
        [row addSubview:logo];
    }
    [row addSubview:[c text:label font:[NSFont systemFontOfSize:(name ? 13 : 12) weight:(name ? NSFontWeightSemibold : NSFontWeightMedium)]
                      color:(name ? NSColor.labelColor : NSColor.secondaryLabelColor)
                         at:NSMakeRect(kAINameX, (h - 16) / 2, kAINameW + 4, 16) align:NSTextAlignmentLeft]];
    PoolSketch *g = [[PoolSketch alloc] initWithFrame:NSMakeRect(kGaugeX, (h - 20) / 2, kGaugeW, 20)];
    g.a = a; g.b = b < 0 ? a : b; g.style = b < 0 ? PoolTwoRows : style;
    [row addSubview:g];
    NSFont *big = [NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightSemibold];
    if (pair) {
        NSFont *small = [NSFont monospacedDigitSystemFontOfSize:(style == PoolTight ? 11 : 13) weight:NSFontWeightSemibold];
        [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", a * 100] font:small color:AIQuotaColor(a)
                             at:NSMakeRect(kValueX, h / 2 - (style == PoolTight ? 1 : 0), kValueW, h / 2) align:NSTextAlignmentRight]];
        [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", b * 100] font:small color:AIQuotaColor(b)
                             at:NSMakeRect(kValueX, (style == PoolTight ? 1 : 0), kValueW, h / 2) align:NSTextAlignmentRight]];
    } else {
        BOOL grokFirst = style == PoolInnerLine || style == PoolUnderline || style == PoolGrokOverlay;
        double shown = b < 0 ? a : style == PoolMarker ? a : grokFirst ? b : MIN(a, b);
        [row addSubview:[c text:[NSString stringWithFormat:@"%.0f%%", shown * 100] font:big color:AIQuotaColor(shown)
                             at:NSMakeRect(kValueX, (h - kValueH) / 2, kValueW, kValueH) align:NSTextAlignmentRight]];
    }
    if (datum) [row addSubview:[c text:datum font:[NSFont monospacedDigitSystemFontOfSize:kDatumFont weight:NSFontWeightRegular]
                                 color:NSColor.secondaryLabelColor at:NSMakeRect(kDatumX, (h - kDatumH) / 2, kDatumW, kDatumH) align:NSTextAlignmentLeft]];
    return row;
}

static BOOL CursorSheet(NSString *path) {
    Controller *c = [Controller new];
    NSArray *variants = getenv("SHEET_ALL") ? @[@[@"A  today: two thin lanes, two numbers", @(PoolToday)],
                          @[@"B  one bar: solid = tighter pool, pale = the other", @(PoolOverlay)],
                          @[@"C  two lanes squeezed into one bar's height", @(PoolTight)],
                          @[@"D  API bar, Grok as a tick", @(PoolMarker)],
                          @[@"E  a second plain row for Grok/Composer", @(PoolTwoRows)]]
                        : @[@[@"F  Grok bar, API as a line riding inside it", @(PoolInnerLine)],
                          @[@"G  Grok bar, API as a hairline tucked under it", @(PoolUnderline)],
                          @[@"H  Grok bar pale to 41, API share solid to 17", @(PoolGrokOverlay)]];
    NSMutableArray *builders = [NSMutableArray array];
    for (NSArray *v in variants) {
        PoolStyle style = [v[1] integerValue];
        [builders addObject:^NSView *(NSAppearanceName look) {
            NSMutableArray *rows = [NSMutableArray arrayWithObjects:
                QuotaRowSketch(c, @"Claude", @"Claude", 0.44, -1, @"resets Tue", style),
                QuotaRowSketch(c, @"Codex", @"Codex", 0.51, -1, @"resets Wed", style), nil];
            if (style == PoolTwoRows) {
                [rows addObject:QuotaRowSketch(c, @"Cursor", @"Cursor", 0.17, -1, @"resets 3 Nov", style)];
                [rows addObject:QuotaRowSketch(c, nil, @"Grok", 0.41, -1, nil, style)];
            } else {
                [rows addObject:QuotaRowSketch(c, @"Cursor", @"Cursor", 0.17, 0.41, @"resets 3 Nov", style)];
            }
            return TitledPanel(v[0], rows, look, c);
        }];
    }
    return WriteSheet(builders, path);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        if (argc < 3) { fprintf(stderr, "usage: ux-sheet pace|power|system|trend|cursor out.png\n"); return 2; }
        NSString *path = [NSString stringWithUTF8String:argv[2]];
        if (!strcmp(argv[1], "power")) return PowerSheet(path) ? 0 : 1;
        if (!strcmp(argv[1], "system")) return SystemSheet(path) ? 0 : 1;
        if (!strcmp(argv[1], "trend")) return TrendSheet(path) ? 0 : 1;
        if (!strcmp(argv[1], "cursor")) return CursorSheet(path) ? 0 : 1;
        Controller *c = [Controller new];
        NSArray *variants = @[@[@"A  today (no pace)", @(PaceNone)],
                              @[@"B  time bug: vertical bar at time left", @(PaceTick)],
                              @[@"C  bug + shortfall shaded red", @(PaceDeficit)],
                              @[@"F  shortfall only while behind; nothing when on track", @(PaceShortfallOnly)],
                              @[@"E  used, filling left to right", @(PaceUsed)]];
        CGFloat gap = 16, colW = kW;
        NSMutableArray *panels = [NSMutableArray array];
        CGFloat rowH = 0;
        for (NSArray *v in variants) {
            NSView *light = SheetPanel(v[0], [v[1] integerValue], NSAppearanceNameAqua, c);
            NSView *dark = SheetPanel(v[0], [v[1] integerValue], NSAppearanceNameDarkAqua, c);
            [panels addObject:@[light, dark]];
            rowH = MAX(rowH, NSHeight(light.frame));
        }
        CGFloat sheetW = gap + 2 * (colW + gap), sheetH = gap + variants.count * (rowH + gap);
        FlippedView *sheet = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, sheetW, sheetH)];
        sheet.wantsLayer = YES;
        sheet.layer.backgroundColor = [NSColor colorWithWhite:0.55 alpha:1].CGColor;
        for (NSUInteger i = 0; i < panels.count; i++) {
            for (NSUInteger j = 0; j < 2; j++) {
                NSView *p = panels[i][j];
                p.frame = NSMakeRect(gap + j * (colW + gap), gap + i * (rowH + gap), colW, rowH);
                [sheet addSubview:p];
            }
        }
        NSBitmapImageRep *rep = [sheet bitmapImageRepForCachingDisplayInRect:sheet.bounds];
        [sheet cacheDisplayInRect:sheet.bounds toBitmapImageRep:rep];
        return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                   writeToFile:path atomically:YES] ? 0 : 1;
    }
}
